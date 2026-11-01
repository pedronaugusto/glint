// review 6: ud/v13_some_path.zig
const std = @import("std");
const W = struct { data: [4]u8, n: u32 };
fn kill(w: *W) void {
    w.* = undefined;
}
pub fn f(c: bool) u8 {
    var w: W = .{ .data = .{ 1, 2, 3, 4 }, .n = 0 };
    if (c) kill(&w);
    return w.data[0];
}
