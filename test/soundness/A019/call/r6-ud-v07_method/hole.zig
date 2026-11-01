// review 6: ud/v07_method.zig
const std = @import("std");
const W = struct {
    data: [4]u8,
    n: u32,
    fn kill(w: *W) void {
        w.* = undefined;
    }
};
pub fn f() u8 {
    var w: W = .{ .data = .{ 1, 2, 3, 4 }, .n = 0 };
    w.kill();
    return w.data[0];
}
