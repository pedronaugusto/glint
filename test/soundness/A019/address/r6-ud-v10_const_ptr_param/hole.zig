// review 6: ud/v10_const_ptr_param.zig
const std = @import("std");
const W = struct { data: [4]u8, n: u32 };
fn kill(w: *W) void {
    w.* = undefined;
}
fn drop(w: *W) void {
    const q = w;
    kill(q);
}
// The callee hands the parameter on through a local.
pub fn f() u8 {
    var w: W = .{ .data = .{ 1, 2, 3, 4 }, .n = 0 };
    drop(&w);
    return w.data[0];
}
