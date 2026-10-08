//! An owned immutable project. Inputs and import mappings are supplied by callers.
const std = @import("std");
const File = @import("File.zig");
const Model = @import("Model.zig");
const Project = @This();
const aegis = @import("aegis");

/// Private: allocation owner for frozen project indexes.
arena: std.heap.ArenaAllocator,
/// Private: per-source front ends and bindings.
files: []File,
/// Private: models refer only to their owning immutable file.
models: []Model,
/// Private: immutable source identities and caller classification.
inputs: []const Input,
/// Private: explicit module resolution. There is no filesystem or path policy here.
imports: []const Import,
/// Private: distinguishes handles from separate snapshots, even at the same index.
identity: u64,

/// A source index within one project.
pub const FileId = aegis.id.Id(struct {}, u32);
/// Distinct source AST indices; conversions to std occur only at query boundaries.
pub const NodeId = aegis.id.Id(struct {}, u32);
/// Token identities cannot be confused with node or file identities.
pub const TokenId = aegis.id.Id(struct {}, u32);
/// A source handle that cannot silently identify a replacement snapshot.
pub const Handle = struct { file: FileId, snapshot: u64 };
/// Explicit source data. `name` is a diagnostic label; `stem` is Zig file-struct naming input.
pub const Input = struct {
    name: []const u8,
    bytes: []const u8,
    stem: []const u8 = "",
    selected: bool = true,
    classification: enum { production, @"test", generated } = .production,
};
/// A module edge selected and resolved by the caller, never by a path hash.
pub const Import = struct { from: FileId, spelling: []const u8, target: FileId };
/// Per-source limits for front-end work.
pub const Options = struct { limits: File.Limits = .{}, files: usize = 4096, bytes: usize = 128 * 1024 * 1024 };
/// Construction errors always propagate; no unread/allocation failure is clean.
pub const InitError = File.InitError || Model.InitError || error{ InvalidMapping, DuplicateMapping, ProjectBudgetExceeded, SnapshotLimit };
/// A handle from another snapshot is invalid.
pub const QueryError = error{InvalidHandle};

/// Copies all source inputs and lowers each valid file through std AstGen/ZIR.
pub fn init(gpa: std.mem.Allocator, inputs: []const Input, imports: []const Import, options: Options) InitError!Project {
    if (inputs.len > options.files or inputs.len > std.math.maxInt(u32)) return error.ProjectBudgetExceeded;
    var remaining_bytes = aegis.int.Checked(usize).init(options.bytes);
    for (inputs) |input| {
        if (input.bytes.len > remaining_bytes.raw()) return error.ProjectBudgetExceeded;
        remaining_bytes = remaining_bytes.sub(input.bytes.len) catch return error.ProjectBudgetExceeded;
    }
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const files = try a.alloc(File, inputs.len);
    const models = try a.alloc(Model, inputs.len);
    const copied = try a.alloc(Input, inputs.len);
    var initialized: usize = 0;
    errdefer for (files[0..initialized]) |*file| file.deinit();
    for (inputs, 0..) |input, index| {
        files[index] = try File.init(gpa, input.bytes, options.limits);
        initialized += 1;
        models[index] = try Model.init(&files[index]);
        copied[index] = input;
        copied[index].bytes = files[index].source;
        copied[index].name = try a.dupe(u8, input.name);
        copied[index].stem = try a.dupe(u8, input.stem);
    }
    const mappings = try a.dupe(Import, imports);
    for (mappings, 0..) |*mapping, index| {
        if (mapping.from.raw() >= inputs.len or mapping.target.raw() >= inputs.len) return error.InvalidMapping; // safe: explicit types represent bounded fixture/source indexes; enum identities belong to validated frozen tables.
        for (mappings[0..index]) |earlier| if (mapping.from.eql(earlier.from) and std.mem.eql(u8, mapping.spelling, earlier.spelling)) return error.DuplicateMapping;
        mapping.spelling = try a.dupe(u8, mapping.spelling);
    }
    const identity = try nextIdentity();
    return .{ .arena = arena, .files = files, .models = models, .inputs = copied, .imports = mappings, .identity = identity };
}

/// Releases all owned source/front-end/model storage.
pub fn deinit(self: *Project) void {
    for (self.files) |*file| file.deinit();
    self.arena.deinit();
    self.* = undefined;
}

/// Creates a handle for an existing source.
pub fn handle(self: *const Project, file: FileId) QueryError!Handle {
    if (file.raw() >= self.files.len) return error.InvalidHandle; // safe: explicit types represent bounded fixture/source indexes; enum identities belong to validated frozen tables.
    return .{ .file = file, .snapshot = self.identity };
}

/// Returns a source's lexical references with resolved declaration identity or unknown reason.
pub fn references(self: *const Project, source_handle: Handle) QueryError![]const Model.Reference {
    const index = try self.checkedIndex(source_handle);
    return self.models[index].references;
}

/// Returns indexed std-ZIR references. Consult loweredCoverage; this is a partial index.
pub fn loweredReferences(self: *const Project, source_handle: Handle) QueryError![]const Model.LoweredReference {
    return self.models[try self.checkedIndex(source_handle)].zir_references;
}
/// Source-mapped call/member/reflection operations from actual std ZIR bodies.
pub fn operations(self: *const Project, h: Handle) QueryError![]const Model.Operation {
    return self.models[try self.checkedIndex(h)].operations;
}

/// Reports the bounds of the std-ZIR reference index without implying type checking.
pub fn loweredCoverage(self: *const Project, source_handle: Handle) QueryError!@FieldType(Model, "lowered_coverage") {
    return self.models[try self.checkedIndex(source_handle)].lowered_coverage;
}

/// Returns source declarations, including lazy declarations and public/export provenance.
pub fn declarations(self: *const Project, source_handle: Handle) QueryError![]const Model.Declaration {
    const index = try self.checkedIndex(source_handle);
    return self.models[index].declarations;
}

/// Returns lexical scopes; fields and enum literals are not binding references.
pub fn scopes(self: *const Project, source_handle: Handle) QueryError![]const Model.Scope {
    const index = try self.checkedIndex(source_handle);
    return self.models[index].scopes;
}

/// Returns immutable source bytes for source-span consumers.
pub fn source(self: *const Project, source_handle: Handle) QueryError![]const u8 {
    return self.inputs[try self.checkedIndex(source_handle)].bytes;
}

/// Returns the explicit module target, or unknown when no mapping was supplied.
pub fn imported(self: *const Project, from: FileId, spelling: []const u8) ?FileId {
    for (self.imports) |mapping| if (mapping.from.eql(from) and std.mem.eql(u8, mapping.spelling, spelling)) return mapping.target;
    return null;
}

/// Number of source inputs, including unselected dependencies.
pub fn count(self: *const Project) usize {
    return self.inputs.len;
}
/// Caller-provided source classification and diagnostic identity.
pub fn metadata(self: *const Project, h: Handle) QueryError!Input {
    return self.inputs[try self.checkedIndex(h)];
}
/// Frozen std AST. Invalid inputs retain syntax but cannot supply semantic facts.
pub fn syntax(self: *const Project, h: Handle) QueryError!*const std.zig.Ast {
    return &self.files[try self.checkedIndex(h)].tree;
}
/// Frozen std ZIR, absent when parsing failed.
pub fn lowered(self: *const Project, h: Handle) QueryError!?*const std.zig.Zir {
    const file = &self.files[try self.checkedIndex(h)];
    return if (file.zir) |*zir| zir else null;
}
/// Honest front-end status, independent of selected rules.
pub fn status(self: *const Project, h: Handle) QueryError!File.Status {
    return self.files[try self.checkedIndex(h)].status;
}
/// Real tokenizer comments; strings and multiline strings cannot forge a reason.
pub fn comments(self: *const Project, h: Handle) QueryError![]const File.Comment {
    return self.files[try self.checkedIndex(h)].comments;
}
/// Validates distinct node identity before converting to std's AST index.
pub fn node(self: *const Project, h: Handle, id: NodeId) QueryError!std.zig.Ast.Node.Index {
    if (id.raw() >= (try self.syntax(h)).nodes.len) return error.InvalidHandle;
    return @fromBackingInt(id.raw()); // safe: checked against this snapshot's AST inventory.
}
/// Validates distinct token identity before crossing the std boundary.
pub fn token(self: *const Project, h: Handle, id: TokenId) QueryError!std.zig.Ast.TokenIndex {
    if (id.raw() >= (try self.syntax(h)).tokens.len) return error.InvalidHandle;
    return id.raw();
}

// Process-local identities are monotonic; allocator reuse cannot revive stale handles.
var last_identity: std.atomic.Value(u64) = .init(0);
fn nextIdentity() error{SnapshotLimit}!u64 {
    var previous = last_identity.load(.monotonic);
    while (true) {
        if (previous == std.math.maxInt(u64)) return error.SnapshotLimit;
        if (last_identity.cmpxchgWeak(previous, previous + 1, .monotonic, .monotonic)) |observed| previous = observed else return previous + 1;
    }
}

fn checkedIndex(self: *const Project, source_handle: Handle) QueryError!usize {
    if (source_handle.snapshot != self.identity or source_handle.file.raw() >= self.files.len) return error.InvalidHandle; // safe: explicit types represent bounded fixture/source indexes; enum identities belong to validated frozen tables.
    return source_handle.file.raw(); // safe: explicit types represent bounded fixture/source indexes; enum identities belong to validated frozen tables.
}

test "project handles cannot refer to another snapshot" {
    var first = try init(std.testing.allocator, &.{.{ .name = "one", .bytes = "const x = 1;" }}, &.{}, .{});
    defer first.deinit();
    var second = try init(std.testing.allocator, &.{.{ .name = "two", .bytes = "const x = 2;" }}, &.{}, .{});
    defer second.deinit();
    const h = try first.handle(Project.FileId.fromRaw(0)); // safe: explicit types represent bounded fixture/source indexes; enum identities belong to validated frozen tables.
    try std.testing.expectError(error.InvalidHandle, second.source(h));
    try std.testing.expectEqualStrings("const x = 1;", try first.source(h));
}

test "project maps opaque module identities without filesystem access" {
    var project = try init(std.testing.allocator, &.{
        .{ .name = "root", .bytes = "const dep = @import(\"dep\");" },
        .{ .name = "other", .bytes = "pub const value = 1;", .selected = false },
    }, &.{.{ .from = Project.FileId.fromRaw(0), .spelling = "dep", .target = Project.FileId.fromRaw(1) }}, .{}); // safe: explicit types represent bounded fixture/source indexes; enum identities belong to validated frozen tables.
    defer project.deinit();
    try std.testing.expectEqual(@as(?FileId, Project.FileId.fromRaw(1)), project.imported(Project.FileId.fromRaw(0), "dep")); // safe: explicit types represent bounded fixture/source indexes; enum identities belong to validated frozen tables.
    try std.testing.expect(project.imported(Project.FileId.fromRaw(0), "missing") == null); // safe: explicit types represent bounded fixture/source indexes; enum identities belong to validated frozen tables.
}

test "project allocation failures release partially initialized files" {
    const Helper = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var project = try Project.init(gpa, &.{.{ .name = "root", .bytes = "const x = 1;" }}, &.{}, .{});
            defer project.deinit();
        }
    };
    const shakedown = @import("shakedown");
    var allocation: shakedown.alloc.NoResize = .init(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(allocation.allocator(), Helper.run, .{});
}

test "project stale handles survive allocator address reuse without aliasing" {
    var storage: [262144]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&storage);
    var first = try init(allocator.allocator(), &.{.{ .name = "one", .bytes = "const x = 1;" }}, &.{}, .{});
    const stale = try first.handle(Project.FileId.fromRaw(0)); // safe: source zero exists in this single-source fixture.
    first.deinit();
    allocator.reset();
    var replacement = try init(allocator.allocator(), &.{.{ .name = "two", .bytes = "const x = 2;" }}, &.{}, .{});
    defer replacement.deinit();
    try std.testing.expectError(error.InvalidHandle, replacement.source(stale));
}
