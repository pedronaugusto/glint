// The context is reset between two ranked acquisitions while the first guard is held: the second is checked
// against an empty context, so the Order does not rank b against a.
const std = @import("std");
const aegis = @import("aegis");
const L = aegis.BlockingGuarded(u32);
const O = aegis.Order(&.{ .{ .name = "a" }, .{ .name = "b", .after = &.{0} } });
const A = O.Ordered(L, 0);
const B = O.Ordered(L, 1);
pub fn both(a: *A, b: *B, io: std.Io) void {
    var ctx: O.Context = .{};
    var gb = b.acquireOrderedUncancelable(io, &ctx);
    defer gb.deinit(io);
    ctx = .{};
    var ga = a.acquireOrderedUncancelable(io, &ctx);
    defer ga.deinit(io);
}
