// A021: a local ordered lock's address taken, its ranked acquisition through it: none.
const aegis = @import("aegis");
const std = @import("std");
const Locks = aegis.Order(&.{.{ .name = "count" }});
const Counter = Locks.Ordered(aegis.BlockingGuarded(u32), 0);
pub fn count(io: std.Io, context: *Locks.Context) !u32 {
    var local: Counter = .init(.init(0));
    const held = &local;
    var guard = try held.acquireOrdered(io, context);
    defer guard.deinit(io);
    guard.value().* += 1;
    return guard.value().*;
}
