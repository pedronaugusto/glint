// matrix: P005 jump: std.debug.print carried out of a labeled block and called
const std = @import("std");
fn quiet(comptime format: []const u8, args: anytype) void {
    _ = format;
    _ = args;
}
pub fn run() void {
    const say = blk: {
        break :blk std.debug.print;
    };
    say("x\n", .{});
}
