//! An owned immutable project. Inputs and import mappings are supplied by callers.
const std = @import("std");
const File = @import("File.zig");
const Model = @import("Model.zig");
const Project = @This();
const aegis = @import("aegis");

/// Private: allocation owner for frozen project indexes.
arena: std.heap.ArenaAllocator,
/// Private: per-source front ends, bindings and caller classification, one entry per input
/// in the caller's order.
sources: []Source,
/// Private: explicit module resolution. There is no filesystem or path policy here.
imports: []const Edge,
/// Private: distinguishes handles from separate snapshots, even at the same index.
identity: u64,

/// One source: its front end, its model (which refers only to this immutable file), and the
/// input it was made from.
pub const Source = struct {
    file: File,
    model: Model,
    input: Input,
    id: Id,

    /// A source within one project, made only by `init` counting the sources: an id names
    /// one of them. A caller turns its input's position into one with `fileAt`.
    pub const Id = enum(u32) { _ };
};
/// A source within one project.
pub const FileId = Source.Id;
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
    /// Module names the build binds in no module that compiles this file. Zig compiles an
    /// `@import` of one only where the build would fail, so code that needs one is not part of
    /// this build. The caller states this from the build's own configuration; a name merely
    /// left unmapped stays unknown.
    absent: []const []const u8 = &.{},
    /// The package whose tree holds this file: the name its nearest `build.zig.zon` gives, as
    /// the caller states it. Empty when unknown. A policy names packages by it (an owner of a
    /// disallowed declaration).
    package: []const u8 = "",
    /// That package's identity: the fingerprint its `build.zig.zon` gives, as the caller states
    /// it. Null when unknown. A library the analyses know (aegis) is known by its name and
    /// this, under whatever name a program imports it.
    fingerprint: ?u64 = null,
};
/// A module edge selected and resolved by the caller, never by a path hash: `from` and `target`
/// are positions in the inputs given to `init`.
pub const Import = struct { from: usize, spelling: []const u8, target: usize };
/// An import checked against the inputs.
const Edge = struct { from: FileId, spelling: []const u8, target: FileId };
/// Per-source limits for front-end work.
pub const Options = struct {
    lowering: bool = true,
    limits: File.Limits = .{},
    files: usize = 4096,
    bytes: usize = 128 * 1024 * 1024,
    /// The caller's `Io`, asked for a cancel before each file is parsed and
    /// lowered: a canceled build is `Canceled`. Null: none is asked, and a
    /// canceller waits for every file.
    io: ?std.Io = null,
};
/// Construction errors always propagate; no unread/allocation failure is clean.
pub const InitError = File.InitError || Model.InitError || std.Io.Cancelable || error{ InvalidMapping, DuplicateMapping, ProjectBudgetExceeded, SnapshotLimit };
/// A handle from another snapshot is invalid.
pub const QueryError = error{InvalidHandle};

/// Copies all source inputs and lowers each valid file through std AstGen/ZIR.
pub fn init(gpa: std.mem.Allocator, inputs: []const Input, imports: []const Import, options: Options) InitError!Project {
    if (inputs.len > options.files or inputs.len > std.math.maxInt(u32)) return error.ProjectBudgetExceeded;
    var remaining_bytes = aegis.int.Checked(usize).init(options.bytes);
    for (inputs) |input| {
        remaining_bytes = remaining_bytes.sub(input.bytes.len) catch return error.ProjectBudgetExceeded;
    }
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const sources = try a.alloc(Source, inputs.len);
    var initialized: usize = 0;
    errdefer for (sources[0..initialized]) |*each| each.file.deinit();
    for (sources, inputs, 0..) |*each, input, index| {
        if (options.io) |io| try io.checkCancel();
        each.id = @fromBackingInt(@intCast(index));
        each.file = try File.initWithLowering(gpa, input.bytes, options.limits, options.lowering);
        initialized += 1;
        each.model = try Model.init(&each.file);
        each.input = input;
        each.input.bytes = each.file.source;
        each.input.name = try a.dupe(u8, input.name);
        each.input.stem = try a.dupe(u8, input.stem);
        each.input.package = try a.dupe(u8, input.package);
        const names = try a.alloc([]const u8, input.absent.len);
        for (names, input.absent) |*out, name| out.* = try a.dupe(u8, name);
        each.input.absent = names;
    }
    const mappings = try a.alloc(Edge, imports.len);
    for (mappings, imports, 0..) |*mapping, import, index| {
        if (import.from >= sources.len or import.target >= sources.len) return error.InvalidMapping;
        mapping.* = .{ .from = sources[import.from].id, .spelling = try a.dupe(u8, import.spelling), .target = sources[import.target].id };
        for (mappings[0..index]) |earlier| if (mapping.from == earlier.from and std.mem.eql(u8, mapping.spelling, earlier.spelling)) return error.DuplicateMapping;
    }
    const identity = try nextIdentity();
    return .{ .arena = arena, .sources = sources, .imports = mappings, .identity = identity };
}

/// Releases all owned source/front-end/model storage.
pub fn deinit(self: *Project) void {
    for (self.sources) |*each| each.file.deinit();
    self.arena.deinit();
    self.* = undefined;
}

/// The source made from the input at `position` in the inputs given to `init`.
pub fn fileAt(self: *const Project, position: usize) QueryError!FileId {
    if (position >= self.sources.len) return error.InvalidHandle;
    return self.sources[position].id;
}

/// A source by its id.
pub fn at(self: *const Project, file: FileId) *const Source {
    return &self.sources[@backingInt(file)];
}

/// Creates a handle for an existing source.
pub fn handle(self: *const Project, file: FileId) Handle {
    return .{ .file = file, .snapshot = self.identity };
}

/// Returns a source's lexical references with resolved declaration identity or unknown reason.
pub fn references(self: *const Project, source_handle: Handle) QueryError![]const Model.Reference {
    return (try self.checked(source_handle)).model.references;
}

/// Returns indexed std-ZIR references. Consult loweredCoverage; this is a partial index.
pub fn loweredReferences(self: *const Project, source_handle: Handle) QueryError![]const Model.LoweredReference {
    return (try self.checked(source_handle)).model.zir_references;
}
/// Source-mapped call/member/reflection operations from actual std ZIR bodies.
pub fn operations(self: *const Project, h: Handle) QueryError![]const Model.Operation {
    return (try self.checked(h)).model.operations;
}

/// Reports the bounds of the std-ZIR reference index without implying type checking.
pub fn loweredCoverage(self: *const Project, source_handle: Handle) QueryError!@FieldType(Model, "lowered_coverage") {
    return (try self.checked(source_handle)).model.lowered_coverage;
}

/// Returns source declarations, including lazy declarations and public/export provenance.
pub fn declarations(self: *const Project, source_handle: Handle) QueryError![]const Model.Declaration {
    return (try self.checked(source_handle)).model.declarations;
}

/// Returns lexical scopes; fields and enum literals are not binding references.
pub fn scopes(self: *const Project, source_handle: Handle) QueryError![]const Model.Scope {
    return (try self.checked(source_handle)).model.scopes;
}

/// Returns immutable source bytes for source-span consumers.
pub fn source(self: *const Project, source_handle: Handle) QueryError![]const u8 {
    return (try self.checked(source_handle)).input.bytes;
}

/// Returns the explicit module target, or unknown when no mapping was supplied.
pub fn imported(self: *const Project, from: FileId, spelling: []const u8) ?FileId {
    for (self.imports) |mapping| if (mapping.from == from and std.mem.eql(u8, mapping.spelling, spelling)) return mapping.target;
    return null;
}

/// Whether the build binds no module named `spelling` for `from` (its input's `absent`).
pub fn absent(self: *const Project, from: FileId, spelling: []const u8) bool {
    for (self.at(from).input.absent) |name| if (std.mem.eql(u8, name, spelling)) return true;
    return false;
}

/// Number of source inputs, including unselected dependencies.
pub fn count(self: *const Project) usize {
    return self.sources.len;
}
/// Caller-provided source classification and diagnostic identity.
pub fn metadata(self: *const Project, h: Handle) QueryError!Input {
    return (try self.checked(h)).input;
}
/// Frozen std AST. Invalid inputs retain syntax but cannot supply semantic facts.
pub fn syntax(self: *const Project, h: Handle) QueryError!*const std.zig.Ast {
    return &(try self.checked(h)).file.tree;
}
/// Frozen std ZIR, absent when parsing failed.
pub fn lowered(self: *const Project, h: Handle) QueryError!?*const std.zig.Zir {
    const file = &(try self.checked(h)).file;
    return if (file.zir) |*zir| zir else null;
}
/// Honest front-end status, independent of selected rules.
pub fn status(self: *const Project, h: Handle) QueryError!File.Status {
    return (try self.checked(h)).file.status;
}
/// Real tokenizer comments; strings and multiline strings cannot forge a reason.
pub fn comments(self: *const Project, h: Handle) QueryError![]const File.Comment {
    return (try self.checked(h)).file.comments;
}
/// Validates distinct node identity before converting to std's AST index.
pub fn node(self: *const Project, h: Handle, id: NodeId) QueryError!std.zig.Ast.Node.Index {
    // aegis: no-danger(A004): an identity checked against the length of the table it indexes; the comparison is the bound
    if (id.raw() >= (try self.syntax(h)).nodes.len) return error.InvalidHandle;
    return @fromBackingInt(id.raw());
}
/// Validates distinct token identity before crossing the std boundary.
pub fn token(self: *const Project, h: Handle, id: TokenId) QueryError!std.zig.Ast.TokenIndex {
    // aegis: no-danger(A004): an identity checked against the length of the table it indexes; the comparison is the bound
    if (id.raw() >= (try self.syntax(h)).tokens.len) return error.InvalidHandle;
    return id.raw();
}

// Process-local identities are monotonic; allocator reuse cannot revive stale handles.
const Identity = enum(u64) { _ };
var last_identity: aegis.Atomic(Identity) = .init(@fromBackingInt(0));
fn nextIdentity() error{SnapshotLimit}!u64 {
    var previous = last_identity.load(.monotonic);
    while (true) {
        const raw = @backingInt(previous);
        if (raw == std.math.maxInt(u64)) return error.SnapshotLimit;
        if (last_identity.cmpxchgWeak(previous, @fromBackingInt(raw + 1), .monotonic, .monotonic)) |observed| previous = observed else return raw + 1;
    }
}

fn checked(self: *const Project, source_handle: Handle) QueryError!*const Source {
    if (source_handle.snapshot != self.identity) return error.InvalidHandle;
    return self.at(source_handle.file);
}

test "project handles cannot refer to another snapshot" {
    var first = try init(std.testing.allocator, &.{.{ .name = "one", .bytes = "const x = 1;" }}, &.{}, .{});
    defer first.deinit();
    var second = try init(std.testing.allocator, &.{.{ .name = "two", .bytes = "const x = 2;" }}, &.{}, .{});
    defer second.deinit();
    const h = first.handle(try first.fileAt(0));
    try std.testing.expectError(error.InvalidHandle, second.source(h));
    try std.testing.expectEqualStrings("const x = 1;", try first.source(h));
}

test "project maps opaque module identities without filesystem access" {
    var project = try init(std.testing.allocator, &.{
        .{ .name = "root", .bytes = "const dep = @import(\"dep\");" },
        .{ .name = "other", .bytes = "pub const value = 1;", .selected = false },
    }, &.{.{ .from = 0, .spelling = "dep", .target = 1 }}, .{});
    defer project.deinit();
    try std.testing.expectEqual(@as(?FileId, try project.fileAt(1)), project.imported(try project.fileAt(0), "dep"));
    try std.testing.expect(project.imported(try project.fileAt(0), "missing") == null);
}

test "project stale handles survive allocator address reuse without aliasing" {
    var storage: [262144]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&storage);
    var first = try init(allocator.allocator(), &.{.{ .name = "one", .bytes = "const x = 1;" }}, &.{}, .{});
    const stale = first.handle(try first.fileAt(0));
    first.deinit();
    allocator.reset();
    var replacement = try init(allocator.allocator(), &.{.{ .name = "two", .bytes = "const x = 2;" }}, &.{}, .{});
    defer replacement.deinit();
    try std.testing.expectError(error.InvalidHandle, replacement.source(stale));
}
