// review 6: ud/v12_loop_next_pass.zig
const std = @import("std");
const W = struct { data: [4]u8, n: u32 };
fn kill(w: *W) void {
    w.* = undefined;
}
// Given undefined at the end of a pass, read at the start of the next.
pub fn f(k: usize) u8 {
    var w: W = .{ .data = .{ 1, 2, 3, 4 }, .n = 0 };
    var acc: u8 = 0;
    for (0..k) |_| {
        acc +%= w.data[0];
        kill(&w);
    }
    return acc;
}
