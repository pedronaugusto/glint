// matrix: P005 aggregate: std.debug.print put in a struct literal and called through its field
const std = @import("std");
fn quiet(comptime format: []const u8, args: anytype) void {
    _ = format;
    _ = args;
}
pub fn run() void {
    const out = .{ .say = std.debug.print };
    out.say("x\n", .{});
}
