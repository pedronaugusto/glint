// matrix: P005 jump: the same, through the program's own quiet output
const std = @import("std");
fn quiet(comptime format: []const u8, args: anytype) void {
    _ = format;
    _ = args;
}
pub fn run() void {
    const say = blk: {
        break :blk quiet;
    };
    say("x\n", .{});
}
