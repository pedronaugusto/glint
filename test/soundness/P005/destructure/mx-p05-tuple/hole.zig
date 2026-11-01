// matrix: P005 destructure: std.debug.print destructured out of a tuple and called
const std = @import("std");
fn quiet(comptime format: []const u8, args: anytype) void {
    _ = format;
    _ = args;
}
pub fn run() void {
    const say, const n = .{ std.debug.print, 1 };
    say("{d}\n", .{n});
}
