// review 6: a03/h06_child_wait_is_release.zig
const std = @import("std");
// A child process: `wait` is not a release of the stdin/stdout files the child opened.
pub fn f(io: std.Io, gpa: std.mem.Allocator) !void {
    _ = gpa;
    var child = try std.process.spawn(io, .{ .argv = &.{"true"}, .stdin = .pipe });
    _ = try child.wait(io);
}
