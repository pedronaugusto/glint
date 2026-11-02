// The helper's third argument is read as the context its ranked acquisition takes, but the helper ranks b
// through a context of its own: a is then taken through ctx, which never saw b held (an inversion unchecked).
const std = @import("std");
const aegis = @import("aegis");
const L = aegis.BlockingGuarded(u32);
const O = aegis.Order(&.{ .{ .name = "a" }, .{ .name = "b", .after = &.{0} } });
const A = O.Ordered(L, 0);
const B = O.Ordered(L, 1);
var side: O.Context = .{};
fn lockB(b: *B, io: std.Io, ctx: *O.Context) @TypeOf(b.acquireOrderedUncancelable(io, ctx)) {
    return b.acquireOrderedUncancelable(io, &side);
}
pub fn both(a: *A, b: *B, io: std.Io) void {
    var ctx: O.Context = .{};
    var gb = lockB(b, io, &ctx);
    defer gb.deinit(io);
    var ga = a.acquireOrderedUncancelable(io, &ctx);
    defer ga.deinit(io);
}
