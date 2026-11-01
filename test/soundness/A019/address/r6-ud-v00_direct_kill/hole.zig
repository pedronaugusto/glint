// review 6: ud/v00_direct_kill.zig
const std = @import("std");
const W = struct { data: [4]u8, n: u32 };
fn kill(w: *W) void {
    w.* = undefined;
}
// Twin: a direct call that gives the local undefined, then a read.
pub fn f() u8 {
    var w: W = .{ .data = .{ 1, 2, 3, 4 }, .n = 0 };
    kill(&w);
    return w.data[0];
}
