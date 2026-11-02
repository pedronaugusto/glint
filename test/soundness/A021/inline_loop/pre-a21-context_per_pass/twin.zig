// One context for every pass: the Order checks each acquisition against the guard still held.
const std = @import("std");
const aegis = @import("aegis");
const L = aegis.BlockingGuarded(u32);
const O = aegis.Order(&.{ .{ .name = "a" }, .{ .name = "b", .after = &.{0} } });
const A = O.Ordered(L, 0);
pub fn each(locks: []const *A, io: std.Io) void {
    var ctx: O.Context = .{};
    for (locks) |l| {
        var g = l.acquireOrderedUncancelable(io, &ctx);
        if (g.value().* == 0) continue;
        g.deinit(io);
    }
}
