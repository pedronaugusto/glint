// matrix: P005 assignment: the same, through the program's own quiet output
const std = @import("std");
fn quiet(comptime format: []const u8, args: anytype) void {
    _ = format;
    _ = args;
}
const say = quiet;
pub fn run() void {
    say("x\n", .{});
}
