// matrix: P005 branch: std.debug.print chosen by a comptime if expression and called
const std = @import("std");
fn quiet(comptime format: []const u8, args: anytype) void {
    _ = format;
    _ = args;
}
const verbose = true;
pub fn run() void {
    const say = if (verbose) std.debug.print else quiet;
    say("x\n", .{});
}
