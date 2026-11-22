// A021: an ordered lock's pointer chosen by an if, its ranked acquisition through it: none.
const aegis = @import("aegis");
const std = @import("std");
const Locks = aegis.Order(&.{.{ .name = "count" }});
const Counter = Locks.Ordered(aegis.BlockingGuarded(u32), 0);
pub fn bump(io: std.Io, context: *Locks.Context, first: bool, a: *Counter, b: *Counter) !void {
    const held = if (first) a else b;
    var guard = try held.acquireOrdered(io, context);
    defer guard.deinit(io);
    guard.value().* += 1;
}
