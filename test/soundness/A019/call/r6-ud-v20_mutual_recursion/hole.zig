// review 6: ud/v20_mutual_recursion.zig
const std = @import("std");
const W = struct { data: [4]u8, n: u32 };
fn a(w: *W, n: u32) void {
    if (n == 0) return;
    b(w, n - 1);
}
fn b(w: *W, n: u32) void {
    if (n == 1) {
        w.* = undefined;
        return;
    }
    a(w, n - 1);
}
// Mutual recursion gives w undefined on one path.
pub fn f() u8 {
    var w: W = .{ .data = .{ 1, 2, 3, 4 }, .n = 0 };
    a(&w, 5);
    return w.data[0];
}
