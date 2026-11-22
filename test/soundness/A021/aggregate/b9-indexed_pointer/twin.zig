// A021: an ordered lock's pointer an element of an array literal, its ranked acquisition: none.
const aegis = @import("aegis");
const std = @import("std");
const Locks = aegis.Order(&.{.{ .name = "count" }});
const Counter = Locks.Ordered(aegis.BlockingGuarded(u32), 0);
pub fn bump(io: std.Io, context: *Locks.Context, a: *Counter, b: *Counter) !void {
    const pair = [2]*Counter{ a, b };
    const held = pair[1];
    var guard = try held.acquireOrdered(io, context);
    defer guard.deinit(io);
    guard.value().* += 1;
}
