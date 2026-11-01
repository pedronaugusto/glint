// matrix: P005 inline_loop: the same, through the program's own quiet output
const std = @import("std");
fn quiet(comptime format: []const u8, args: anytype) void {
    _ = format;
    _ = args;
}
pub fn run() void {
    inline for (.{quiet}) |say| say("x\n", .{});
}
