// The context is a pointer parameter, and a second parameter the caller gives the same context resets it between
// the two ranked acquisitions: the Order never sees b held.
const std = @import("std");
const aegis = @import("aegis");
const L = aegis.BlockingGuarded(u32);
const O = aegis.Order(&.{ .{ .name = "a" }, .{ .name = "b", .after = &.{0} } });
const A = O.Ordered(L, 0);
const B = O.Ordered(L, 1);
fn both(a: *A, b: *B, io: std.Io, ctx: *O.Context, again: *O.Context) void {
    var gb = b.acquireOrderedUncancelable(io, ctx);
    defer gb.deinit(io);
    again.* = .{};
    var ga = a.acquireOrderedUncancelable(io, ctx);
    defer ga.deinit(io);
}
pub fn run(a: *A, b: *B, io: std.Io) void {
    var ctx: O.Context = .{};
    both(a, b, io, &ctx, &ctx);
}
