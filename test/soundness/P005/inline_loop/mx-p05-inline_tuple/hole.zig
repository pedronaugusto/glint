// matrix: P005 inline_loop: std.debug.print called by an inline loop over a tuple of functions
const std = @import("std");
fn quiet(comptime format: []const u8, args: anytype) void {
    _ = format;
    _ = args;
}
pub fn run() void {
    inline for (.{std.debug.print}) |say| say("x\n", .{});
}
