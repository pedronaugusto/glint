const std = @import("std");
const Out = struct { n: *u64, r: *std.Io.Reader };
pub fn f(r: *std.Io.Reader, cb: *const fn (Out) anyerror!void) !u64 {
    var n: u64 = 0;
    try cb(.{ .n = &n, .r = r });
    return n *| 3;
}
