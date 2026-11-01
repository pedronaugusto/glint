// review 6: ud/v02b_field_assign_store.zig
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
pub fn arm() void {
    ops.free = kill;
}
pub fn f() u8 {
    var w: W = .{ .data = .{ 1, 2, 3, 4 }, .n = 0 };
    ops.free(&w);
    return w.data[0];
}
