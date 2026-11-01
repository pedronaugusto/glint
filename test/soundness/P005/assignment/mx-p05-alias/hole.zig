// matrix: P005 assignment: std.debug.print called through a container-level alias
const std = @import("std");
fn quiet(comptime format: []const u8, args: anytype) void {
    _ = format;
    _ = args;
}
const say = std.debug.print;
pub fn run() void {
    say("x\n", .{});
}
