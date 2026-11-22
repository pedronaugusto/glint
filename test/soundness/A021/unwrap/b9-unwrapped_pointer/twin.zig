// A021: an ordered lock's pointer unwrapped from an optional by .?, its ranked acquisition: none.
const aegis = @import("aegis");
const std = @import("std");
const Locks = aegis.Order(&.{.{ .name = "count" }});
const Counter = Locks.Ordered(aegis.BlockingGuarded(u32), 0);
pub fn bump(io: std.Io, context: *Locks.Context, g: ?*Counter) !void {
    const held = g.?;
    var guard = try held.acquireOrdered(io, context);
    defer guard.deinit(io);
    guard.value().* += 1;
}
