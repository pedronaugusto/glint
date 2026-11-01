// matrix: P005 assignment: std.debug.print called through an alias in a nested container
const std = @import("std");
fn quiet(comptime format: []const u8, args: anytype) void {
    _ = format;
    _ = args;
}
const Out = struct {
    const say = std.debug.print;
};
pub fn run() void {
    Out.say("x\n", .{});
}
