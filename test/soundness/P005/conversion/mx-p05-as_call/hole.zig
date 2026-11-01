// matrix: P005 conversion: std.debug.print called through @as to its own type
const std = @import("std");
fn quiet(comptime format: []const u8, args: anytype) void {
    _ = format;
    _ = args;
}
pub fn run() void {
    @as(@TypeOf(std.debug.print), std.debug.print)("x\n", .{});
}
