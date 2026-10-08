//! An owned immutable project. Inputs and import mappings are supplied by callers.
const std = @import("std");
const File = @import("File.zig");
const Model = @import("Model.zig");
const Project = @This();

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
identity: *const u8,

/// A source index within one project.
pub const FileId = enum(u32) { _ };
/// A source handle that cannot silently identify a replacement snapshot.
pub const Handle = struct { file: FileId, snapshot: *const u8 };
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
pub const Options = struct { limits: File.Limits = .{} };
/// Construction errors always propagate; no unread/allocation failure is clean.
pub const InitError = Model.InitError || error{ InvalidMapping, DuplicateMapping };
/// A handle from another snapshot is invalid.
pub const QueryError = error{InvalidHandle};

/// Copies all source inputs and lowers each valid file through std AstGen/ZIR.
pub fn init(gpa: std.mem.Allocator, inputs: []const Input, imports: []const Import, options: Options) InitError!Project {
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
        if (@backingInt(mapping.from) >= inputs.len or @backingInt(mapping.target) >= inputs.len) return error.InvalidMapping;
        for (mappings[0..index]) |earlier| if (mapping.from == earlier.from and std.mem.eql(u8, mapping.spelling, earlier.spelling)) return error.DuplicateMapping;
        mapping.spelling = try a.dupe(u8, mapping.spelling);
    }
    const identity = try a.create(u8);
    identity.* = 0;
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
    if (@backingInt(file) >= self.files.len) return error.InvalidHandle;
    return .{ .file = file, .snapshot = self.identity };
}

/// Returns a source's lexical references with resolved declaration identity or unknown reason.
pub fn references(self: *const Project, source_handle: Handle) QueryError![]const Model.Reference {
    const index = try self.checkedIndex(source_handle);
    return self.models[index].references;
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
    for (self.imports) |mapping| if (mapping.from == from and std.mem.eql(u8, mapping.spelling, spelling)) return mapping.target;
    return null;
}

fn checkedIndex(self: *const Project, source_handle: Handle) QueryError!usize {
    if (source_handle.snapshot != self.identity or @backingInt(source_handle.file) >= self.files.len) return error.InvalidHandle;
    return @backingInt(source_handle.file);
}

test "project handles cannot refer to another snapshot" {
    var first = try init(std.testing.allocator, &.{.{ .name = "one", .bytes = "const x = 1;" }}, &.{}, .{});
    defer first.deinit();
    var second = try init(std.testing.allocator, &.{.{ .name = "two", .bytes = "const x = 2;" }}, &.{}, .{});
    defer second.deinit();
    const h = try first.handle(@fromBackingInt(0));
    try std.testing.expectError(error.InvalidHandle, second.source(h));
    try std.testing.expectEqualStrings("const x = 1;", try first.source(h));
}

test "project maps opaque module identities without filesystem access" {
    var project = try init(std.testing.allocator, &.{
        .{ .name = "root", .bytes = "const dep = @import(\"dep\");" },
        .{ .name = "other", .bytes = "pub const value = 1;", .selected = false },
    }, &.{.{ .from = @fromBackingInt(0), .spelling = "dep", .target = @fromBackingInt(1) }}, .{});
    defer project.deinit();
    try std.testing.expectEqual(@as(?FileId, @fromBackingInt(1)), project.imported(@fromBackingInt(0), "dep"));
    try std.testing.expect(project.imported(@fromBackingInt(0), "missing") == null);
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
