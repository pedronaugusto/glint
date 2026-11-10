//! The compiled facts of a run: the facts files given to it (`facts_format.zig`), each read as
//! untrusted input and kept only whole. A file that is malformed, or that names a source of the
//! run whose bytes are not the ones it was exported from, is refused with its reason and holds
//! nothing: its configuration has no compiled facts, which decides nothing
//! (designs/glint-compiled-facts.md (a), (m)). No query reads these yet.
const std = @import("std");
const aegis = @import("aegis");
const format = @import("facts_format.zig");
const Project = @import("Project.zig");

const Compiled = @This();

/// The files kept, each checked.
kept: []const Kept = &.{},
/// The files refused, each with why.
refused: []const Refused = &.{},

pub const Kept = struct { path: []const u8, view: format.View };
pub const Refused = struct { path: []const u8, why: Why };
pub const Why = union(enum) {
    /// Not a facts file this glint reads.
    malformed: format.Refusal,
    /// A source of the run differs from the one the facts were exported from: its name.
    stale: []const u8,
};

/// A facts file as given: where it was read from and its bytes.
pub const Given = struct { path: []const u8, bytes: []const u8 };

/// The facts of `given`, each file checked against its format and the run's sources. What is
/// kept points into the bytes given, which must outlive it.
pub fn init(gpa: std.mem.Allocator, project: *const Project, given: []const Given) std.mem.Allocator.Error!Compiled {
    var kept: std.ArrayList(Kept) = .empty;
    var refused: std.ArrayList(Refused) = .empty;
    for (given) |each| {
        var refusal: format.Refusal = undefined;
        const view = aegis.input.Untrusted([]const u8).init(each.bytes).parse(&refusal, take) catch {
            try refused.append(gpa, .{ .path = each.path, .why = .{ .malformed = refusal } });
            continue;
        };
        if (stale(project, &view)) |name| {
            try refused.append(gpa, .{ .path = each.path, .why = .{ .stale = name } });
            continue;
        }
        try kept.append(gpa, .{ .path = each.path, .view = view });
    }
    return .{ .kept = try kept.toOwnedSlice(gpa), .refused = try refused.toOwnedSlice(gpa) };
}

fn take(refusal: *format.Refusal, bytes: []const u8) format.Error!format.View {
    return format.View.init(bytes, refusal);
}

/// The first source of the run a facts file names by its path and holds another hash for. A
/// path of the file that is no source of the run is not compared: the run does not read it.
fn stale(project: *const Project, view: *const format.View) ?[]const u8 {
    for (view.files) |file| {
        const path = view.string(file.path);
        for (project.sources) |*source| {
            if (!std.mem.eql(u8, source.input.name, path)) continue;
            var hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(source.file.source, &hash, .{});
            if (!std.mem.eql(u8, &hash, &file.hash)) return source.input.name;
        }
    }
    return null;
}

/// Why `why` refused a file, in words.
pub fn reason(gpa: std.mem.Allocator, why: Why) std.mem.Allocator.Error![]const u8 {
    return switch (why) {
        .malformed => |refusal| gpa.print("not a compiled-facts file this glint reads ({t}): its configuration has no compiled facts", .{refusal}),
        .stale => |name| gpa.print("exported from another {s} than the run reads: its configuration has no compiled facts", .{name}),
    };
}

test "a facts file is kept whole or refused whole: malformed, or stale against a source of the run" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const text = "pub fn id(x: u8) u8 { return x; }";
    var project = try Project.init(gpa, &.{.{ .name = "src/root.zig", .bytes = text }}, &.{}, .{});
    defer project.deinit();

    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &hash, .{});
    var fresh: format.Builder = .{ .gpa = gpa };
    try fresh.files.append(gpa, .{ .path = try fresh.text("src/root.zig"), .hash = hash });
    try fresh.files.append(gpa, .{ .path = try fresh.text("std/mem.zig"), .hash = @splat(1) });
    var old: format.Builder = .{ .gpa = gpa };
    try old.files.append(gpa, .{ .path = try old.text("src/root.zig"), .hash = @splat(2) });

    const compiled = try Compiled.init(gpa, &project, &.{
        .{ .path = "fresh.facts", .bytes = try fresh.finish() },
        .{ .path = "old.facts", .bytes = try old.finish() },
        .{ .path = "junk.facts", .bytes = "not facts" },
    });
    try std.testing.expectEqual(@as(usize, 1), compiled.kept.len);
    try std.testing.expectEqualStrings("fresh.facts", compiled.kept[0].path);
    try std.testing.expectEqual(@as(usize, 2), compiled.refused.len);
    try std.testing.expectEqualStrings("src/root.zig", compiled.refused[0].why.stale);
    try std.testing.expectEqual(format.Refusal.too_short, compiled.refused[1].why.malformed);
}
