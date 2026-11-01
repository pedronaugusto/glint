// review 6: ud/v03_pub_type_consumer.zig
const std = @import("std");
pub const W = struct { data: [4]u8, n: u32 };
fn keep(w: *W) void {
    w.n += 1;
}
// A public type with a public field: a consumer may store a function that gives w undefined.
pub const Ops = struct { free: *const fn (*W) void };
pub const default: Ops = .{ .free = keep };
pub fn f(ops: Ops) u8 {
    var w: W = .{ .data = .{ 1, 2, 3, 4 }, .n = 0 };
    ops.free(&w);
    return w.data[0];
}
