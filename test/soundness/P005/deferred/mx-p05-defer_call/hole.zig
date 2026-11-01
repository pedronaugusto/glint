// matrix: P005 deferred: std.debug.print called by a defer
const std = @import("std");
fn quiet(comptime format: []const u8, args: anytype) void {
    _ = format;
    _ = args;
}
pub fn run() void {
    defer std.debug.print("done\n", .{});
}
