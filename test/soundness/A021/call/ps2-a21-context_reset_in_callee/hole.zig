// A container-level context, reset by a callee between two ranked acquisitions while b is held: a is checked
// against an empty context, so the Order never sees b held.
const std = @import("std");
const aegis = @import("aegis");
const L = aegis.BlockingGuarded(u32);
const O = aegis.Order(&.{ .{ .name = "a" }, .{ .name = "b", .after = &.{0} } });
const A = O.Ordered(L, 0);
const B = O.Ordered(L, 1);
var ctx: O.Context = .{};
fn fresh() void {
    ctx = .{};
}
pub fn both(a: *A, b: *B, io: std.Io) void {
    var gb = b.acquireOrderedUncancelable(io, &ctx);
    defer gb.deinit(io);
    fresh();
    var ga = a.acquireOrderedUncancelable(io, &ctx);
    defer ga.deinit(io);
}
