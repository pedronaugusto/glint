// matrix: P005 capture: std.debug.print the payload an if captures from a comptime-known optional
const std = @import("std");
fn quiet(comptime format: []const u8, args: anytype) void {
    _ = format;
    _ = args;
}
pub fn run() void {
    const maybe: ?@TypeOf(std.debug.print) = std.debug.print;
    if (maybe) |say| say("x\n", .{});
}
