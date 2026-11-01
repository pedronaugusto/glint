// review 6: ud/v16_callee_swap.zig
const std = @import("std");
const W = struct { data: [4]u8, n: u32 };
// The callee swaps the pointee with an undefined value.
fn kill(w: *W) void {
    var junk: W = undefined;
    std.mem.swap(W, w, &junk);
}
pub fn f() u8 {
    var w: W = .{ .data = .{ 1, 2, 3, 4 }, .n = 0 };
    kill(&w);
    return w.data[0];
}
