// The context is made anew each pass while the guard of the last pass is held (the continue skips its release):
// the next pass's ranked acquisition is checked against an empty context, so no Order ranks the two.
const std = @import("std");
const aegis = @import("aegis");
const L = aegis.BlockingGuarded(u32);
const O = aegis.Order(&.{ .{ .name = "a" }, .{ .name = "b", .after = &.{0} } });
const A = O.Ordered(L, 0);
pub fn each(locks: []const *A, io: std.Io) void {
    for (locks) |l| {
        var ctx: O.Context = .{};
        var g = l.acquireOrderedUncancelable(io, &ctx);
        if (g.value().* == 0) continue;
        g.deinit(io);
    }
}
