// A021: a ranked acquisition on an anytype receiver, given an ordered lock: none.
const aegis = @import("aegis");
const std = @import("std");
const Locks = aegis.Order(&.{.{ .name = "count" }});
const Counter = Locks.Ordered(aegis.BlockingGuarded(u32), 0);
fn bumpAny(held: anytype, io: std.Io, context: *Locks.Context) !void {
    var guard = try held.acquireOrdered(io, context);
    defer guard.deinit(io);
    guard.value().* += 1;
}
pub fn bump(io: std.Io, context: *Locks.Context, g: *Counter) !void {
    try bumpAny(g, io, context);
}
