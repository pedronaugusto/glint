// matrix: P005 call: std.debug.print called by @call
const std = @import("std");
fn quiet(comptime format: []const u8, args: anytype) void {
    _ = format;
    _ = args;
}
pub fn run() void {
    @call(.auto, std.debug.print, .{ "x\n", .{} });
}
