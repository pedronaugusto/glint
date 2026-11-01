// matrix: A021 compile_time: two locks ranked by one Order, b after a, through one context
const std = @import("std");
const aegis = @import("aegis");
const L = aegis.BlockingGuarded(u32);
const O = aegis.Order(&.{ .{ .name = "a" }, .{ .name = "b", .after = &.{0} } });
const A = O.Ordered(L, 0);
const B = O.Ordered(L, 1);
pub fn both(a: *A, b: *B, c: *O.Context, io: std.Io) void {
    var ga = a.acquireOrderedUncancelable(io, c);
    defer ga.deinit(io);
    var gb = b.acquireOrderedUncancelable(io, c);
    defer gb.deinit(io);
}
