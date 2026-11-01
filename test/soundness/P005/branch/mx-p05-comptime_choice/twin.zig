// matrix: P005 branch: the same, through the program's own quiet output
const std = @import("std");
fn quiet(comptime format: []const u8, args: anytype) void {
    _ = format;
    _ = args;
}
const verbose = true;
pub fn run() void {
    const say = if (verbose) quiet else quiet;
    say("x\n", .{});
}
