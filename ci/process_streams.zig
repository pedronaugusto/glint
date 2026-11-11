//! glint's output on a file it shares with others: each run writes at the file's offset and
//! moves it, so `glint >> log` keeps what the log held and `{ echo A; glint; echo B; } > f`
//! keeps that order. The tests run from the package root, where `programs.glint` names glint.
const std = @import("std");
const builtin = @import("builtin");
const programs = @import("programs");
const aegis = @import("aegis");

/// A run that prints: a one-line coverage report over a file in the package.
const arguments = [_][]const u8{ programs.glint, "--only", "Z026", "examples/report.zig" };

test "glint >> f keeps what f held and appends each run" {
    // Windows has no O_APPEND to match.
    switch (builtin.os.tag) {
        .windows => return error.SkipZigTest,
        else => {
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const io = std.testing.io;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const output = try alone(a, io);
            try tmp.dir.writeFile(io, .{ .sub_path = "f", .data = "old\nold\n" });
            const fd = try std.posix.openat(tmp.dir.handle, "f", .{ .ACCMODE = .WRONLY, .APPEND = true }, 0);
            const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
            defer file.close(io);
            try runOn(io, file);
            try runOn(io, file);
            try expectFile(a, io, tmp.dir, &.{ "old\nold\n", output, output });
        },
    }
}

test "{ echo A; glint; echo B; } > f keeps that order" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const output = try alone(a, io);
    const file = try tmp.dir.createFile(io, "f", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "A\n");
    try runOn(io, file);
    try file.writeStreamingAll(io, "B\n");
    try expectFile(a, io, tmp.dir, &.{ "A\n", output, "B\n" });
}

/// What the run writes on a pipe, which has no offset.
fn alone(a: std.mem.Allocator, io: std.Io) ![]const u8 {
    const result = try std.process.run(a, io, .{ .argv = &arguments });
    try std.testing.expect(result.stdout.len != 0);
    return result.stdout;
}

/// Runs glint with `file` as its stdout, its stderr dropped.
fn runOn(io: std.Io, file: std.Io.File) !void {
    var child = try std.process.spawn(io, .{ .argv = &arguments, .stdin = .ignore, .stdout = .{ .file = file }, .stderr = .ignore });
    _ = try child.wait(io);
}

fn expectFile(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, parts: []const []const u8) !void {
    const actual = try aegis.own.readFile(io, dir, "f", a, .fromRaw(1024 * 1024));
    try std.testing.expectEqualStrings(try std.mem.concat(a, u8, parts), actual);
}
