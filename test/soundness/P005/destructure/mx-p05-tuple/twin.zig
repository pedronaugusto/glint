// matrix: P005 destructure: the same, through the program's own quiet output
const std = @import("std");
fn quiet(comptime format: []const u8, args: anytype) void {
    _ = format;
    _ = args;
}
pub fn run() void {
    const say, const n = .{ quiet, 1 };
    say("{d}\n", .{n});
}
