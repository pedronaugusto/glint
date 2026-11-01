// matrix: P005 capture: the same, through the program's own quiet output
const std = @import("std");
fn quiet(comptime format: []const u8, args: anytype) void {
    _ = format;
    _ = args;
}
pub fn run() void {
    const maybe: ?@TypeOf(quiet) = quiet;
    if (maybe) |say| say("x\n", .{});
}
