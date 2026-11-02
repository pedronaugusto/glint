// One context through both: the Order's Debug check sees b held when a is taken.
const std = @import("std");
const aegis = @import("aegis");
const L = aegis.BlockingGuarded(u32);
const O = aegis.Order(&.{ .{ .name = "a" }, .{ .name = "b", .after = &.{0} } });
const A = O.Ordered(L, 0);
const B = O.Ordered(L, 1);
pub fn both(a: *A, b: *B, io: std.Io) void {
    var ctx: O.Context = .{};
    var ga = a.acquireOrderedUncancelable(io, &ctx);
    defer ga.deinit(io);
    var gb = b.acquireOrderedUncancelable(io, &ctx);
    defer gb.deinit(io);
}
