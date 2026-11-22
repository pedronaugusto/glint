// A021: the ranked acquisition held by a const as a function value and called: none.
const aegis = @import("aegis");
const std = @import("std");
const Locks = aegis.Order(&.{.{ .name = "count" }});
const Counter = Locks.Ordered(aegis.BlockingGuarded(u32), 0);
const take = Counter.acquireOrdered;
pub fn bump(io: std.Io, context: *Locks.Context, g: *Counter) !void {
    var guard = try take(g, io, context);
    defer guard.deinit(io);
    guard.value().* += 1;
}
