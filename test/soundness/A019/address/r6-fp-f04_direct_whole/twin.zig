// review 6: fp/f04_direct_whole.zig
const std = @import("std");
fn whole(b: *[4]u8) void {
    b.* = .{ 1, 2, 3, 4 };
}
fn use(b: []const u8) void {
    std.debug.print("{any}\n", .{b});
}
pub fn run() void {
    var buf: [4]u8 = undefined;
    whole(&buf);
    use(&buf);
}
