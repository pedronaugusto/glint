//! The compiled facts of a run: the facts files given to it, each read as untrusted input by
//! glint's own reader (compiled_read.zig) and kept only whole. A file that is malformed, or that
//! names a source of the run whose bytes are not the ones it was exported from, is refused with
//! its reason and holds nothing: its configuration has no compiled facts, which decides nothing
//! (designs/glint-compiled-facts.md (a), (m)). No query reads these yet.
const std = @import("std");
const compiled_read = @import("compiled_read.zig");
const Project = @import("Project.zig");

const Compiled = @This();

/// Each file given, in the order given: kept or refused.
files: []const Outcome = &.{},

pub const Outcome = struct {
    path: []const u8,
    read: union(enum) { kept: compiled_read.Records, refused: Why },
};

pub const Why = union(enum) {
    /// Not a facts file this glint reads.
    malformed: compiled_read.Refusal,
    /// A source of the run differs from the one the facts were exported from: its name.
    stale: []const u8,
};

/// A facts file as given: where it was read from and its bytes.
pub const Given = struct { path: []const u8, bytes: []const u8 };

/// The facts of `given`, each file checked against its format and the run's sources. What is
/// kept points into the bytes given, which must outlive it.
pub fn init(gpa: std.mem.Allocator, project: *const Project, given: []const Given, limits: compiled_read.Limits) std.mem.Allocator.Error!Compiled {
    const files = try gpa.alloc(Outcome, given.len);
    for (files, given) |*outcome, each| {
        outcome.* = .{ .path = each.path, .read = try readOne(gpa, project, each.bytes, limits) };
    }
    return .{ .files = files };
}

fn readOne(gpa: std.mem.Allocator, project: *const Project, bytes: []const u8, limits: compiled_read.Limits) std.mem.Allocator.Error!@FieldType(Outcome, "read") {
    const records = compiled_read.read(gpa, .init(bytes), limits) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |refusal| return .{ .refused = .{ .malformed = refusal } },
    };
    if (stale(project, &records)) |name| return .{ .refused = .{ .stale = name } };
    return .{ .kept = records };
}

/// The first source of the run a facts file names by its path and holds another hash for. A
/// path of the file that is no source of the run is not compared: the run does not read it.
fn stale(project: *const Project, records: *const compiled_read.Records) ?[]const u8 {
    for (records.files) |file| {
        const path = records.string(file.path) orelse continue;
        for (project.sources) |*source| {
            if (!std.mem.eql(u8, source.input.name, path)) continue;
            var hash: [32]u8 = @splat(0);
            std.crypto.hash.sha2.Sha256.hash(source.file.source, &hash, .{});
            if (!std.mem.eql(u8, &hash, &file.hash)) return source.input.name;
        }
    }
    return null;
}

/// Why `why` refused a file, in words, to `w`.
pub fn describe(why: Why, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (why) {
        .malformed => |refusal| try w.print("not a compiled-facts file this glint reads ({s}): its configuration has no compiled facts", .{compiled_read.refusalText(refusal)}),
        .stale => |name| try w.print("exported from another {s} than the run reads: its configuration has no compiled facts", .{name}),
    }
}

test "a facts file is kept whole or refused whole: malformed, or stale against a source of the run" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const text = "pub fn id(x: u8) u8 { return x; }";
    var project = try Project.init(gpa, &.{.{ .name = "src/root.zig", .bytes = text }}, &.{}, .{});
    defer project.deinit();

    var hash: [32]u8 = @splat(0);
    std.crypto.hash.sha2.Sha256.hash(text, &hash, .{});
    var fresh: compiled_read.format.Builder = .{ .gpa = gpa };
    try fresh.files.append(gpa, .{ .path = try fresh.text("src/root.zig"), .hash = hash });
    try fresh.files.append(gpa, .{ .path = try fresh.text("std/mem.zig"), .hash = @splat(1) });
    var old: compiled_read.format.Builder = .{ .gpa = gpa };
    try old.files.append(gpa, .{ .path = try old.text("src/root.zig"), .hash = @splat(2) });

    const compiled = try Compiled.init(gpa, &project, &.{
        .{ .path = "fresh.facts", .bytes = try fresh.finish() },
        .{ .path = "old.facts", .bytes = try old.finish() },
        .{ .path = "junk.facts", .bytes = "not facts" },
    }, .{});
    try std.testing.expectEqual(@as(usize, 3), compiled.files.len);
    try std.testing.expectEqualStrings("fresh.facts", compiled.files[0].path);
    try std.testing.expectEqual(@as(usize, 2), compiled.files[0].read.kept.files.len);
    try std.testing.expectEqualStrings("src/root.zig", compiled.files[1].read.refused.stale);
    try std.testing.expectEqual(error.NotAFactsFile, compiled.files[2].read.refused.malformed);
    var words: std.Io.Writer.Allocating = .init(gpa);
    try describe(compiled.files[2].read.refused, &words.writer);
    try std.testing.expectEqualStrings("not a compiled-facts file this glint reads (not a facts file): its configuration has no compiled facts", words.written());
}
