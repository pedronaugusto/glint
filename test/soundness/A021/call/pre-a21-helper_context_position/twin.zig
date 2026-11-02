// The helper ranks b through the context it is given: the Order sees b held when a is taken.
const std = @import("std");
const aegis = @import("aegis");
const L = aegis.BlockingGuarded(u32);
const O = aegis.Order(&.{ .{ .name = "a" }, .{ .name = "b", .after = &.{0} } });
const A = O.Ordered(L, 0);
const B = O.Ordered(L, 1);
fn lockB(b: *B, io: std.Io, ctx: *O.Context) @TypeOf(b.acquireOrderedUncancelable(io, ctx)) {
    return b.acquireOrderedUncancelable(io, ctx);
}
pub fn both(a: *A, b: *B, io: std.Io) void {
    var ctx: O.Context = .{};
    var gb = lockB(b, io, &ctx);
    defer gb.deinit(io);
    var ga = a.acquireOrderedUncancelable(io, &ctx);
    defer ga.deinit(io);
}
