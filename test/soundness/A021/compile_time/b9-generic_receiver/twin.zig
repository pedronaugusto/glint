// A021: a function generic over the lock's type, given an ordered lock: its ranked acquisition: none.
const aegis = @import("aegis");
const std = @import("std");
const Locks = aegis.Order(&.{.{ .name = "count" }});
const Counter = Locks.Ordered(aegis.BlockingGuarded(u32), 0);
fn bumpAny(comptime Lock: type, io: std.Io, context: *Locks.Context, held: *Lock) !void {
    var guard = try held.acquireOrdered(io, context);
    defer guard.deinit(io);
    guard.value().* += 1;
}
pub fn bump(io: std.Io, context: *Locks.Context, g: *Counter) !void {
    try bumpAny(Counter, io, context, g);
}
