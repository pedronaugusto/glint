// A helper ranks a through the caller's context, but resets that context first, while the caller holds b: the
// Order checks a against an empty context and never sees the inversion.
const std = @import("std");
const aegis = @import("aegis");
const L = aegis.BlockingGuarded(u32);
const O = aegis.Order(&.{ .{ .name = "a" }, .{ .name = "b", .after = &.{0} } });
const A = O.Ordered(L, 0);
const B = O.Ordered(L, 1);
fn lockA(a: *A, io: std.Io, ctx: *O.Context) @TypeOf(a.acquireOrderedUncancelable(io, ctx)) {
    ctx.* = .{};
    return a.acquireOrderedUncancelable(io, ctx);
}
pub fn both(a: *A, b: *B, io: std.Io) void {
    var ctx: O.Context = .{};
    var gb = b.acquireOrderedUncancelable(io, &ctx);
    defer gb.deinit(io);
    var ga = lockA(a, io, &ctx);
    defer ga.deinit(io);
}
