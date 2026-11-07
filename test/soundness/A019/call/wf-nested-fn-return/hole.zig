// A callee that gives its parameter `undefined` and returns before writing it again leaves it so.
const W = struct { data: [4]u8, n: u32 };
fn reset(w: *W, c: bool) void {
    w.* = undefined;
    if (c) return;
    w.* = .{ .data = .{ 0, 0, 0, 0 }, .n = 0 };
}
pub fn f(c: bool) u8 {
    var w: W = .{ .data = .{ 1, 2, 3, 4 }, .n = 0 };
    reset(&w, c);
    return w.data[0];
}
