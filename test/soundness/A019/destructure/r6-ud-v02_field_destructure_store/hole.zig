// review 6: ud/v02_field_destructure_store.zig
const std = @import("std");
const W = struct { data: [4]u8, n: u32 };
fn keep(w: *W) void {
    w.n += 1;
}
fn kill(w: *W) void {
    w.* = undefined;
}
const Ops = struct { free: *const fn (*W) void, n: u32 };
var ops: Ops = .{ .free = keep, .n = 0 };
// A destructure stores kill in the field: the call may give w undefined.
pub fn arm() void {
    ops.free, ops.n = .{ kill, 1 };
}
pub fn f() u8 {
    var w: W = .{ .data = .{ 1, 2, 3, 4 }, .n = 0 };
    ops.free(&w);
    return w.data[0];
}
