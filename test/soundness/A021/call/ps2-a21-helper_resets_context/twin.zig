// The helper ranks a through the caller's context as it is: the Order sees b held when a is taken.
const std = @import("std");
const aegis = @import("aegis");
const L = aegis.BlockingGuarded(u32);
const O = aegis.Order(&.{ .{ .name = "a" }, .{ .name = "b", .after = &.{0} } });
const A = O.Ordered(L, 0);
const B = O.Ordered(L, 1);
fn lockA(a: *A, io: std.Io, ctx: *O.Context) @TypeOf(a.acquireOrderedUncancelable(io, ctx)) {
    return a.acquireOrderedUncancelable(io, ctx);
}
pub fn both(a: *A, b: *B, io: std.Io) void {
    var ctx: O.Context = .{};
    var gb = b.acquireOrderedUncancelable(io, &ctx);
    defer gb.deinit(io);
    var ga = lockA(a, io, &ctx);
    defer ga.deinit(io);
}
