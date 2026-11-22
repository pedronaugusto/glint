// A021: an ordered lock's pointer an unrolled loop's capture, its ranked acquisition: none.
const aegis = @import("aegis");
const std = @import("std");
const Locks = aegis.Order(&.{.{ .name = "count" }});
const Counter = Locks.Ordered(aegis.BlockingGuarded(u32), 0);
pub fn bump(io: std.Io, context: *Locks.Context, a: *Counter) !void {
    inline for (.{a}) |held| {
    var guard = try held.acquireOrdered(io, context);
    defer guard.deinit(io);
    guard.value().* += 1;
    }
}
