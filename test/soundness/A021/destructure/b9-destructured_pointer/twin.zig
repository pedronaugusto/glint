// A021: an ordered lock's pointer named by a destructure, its ranked acquisition through it: none.
const aegis = @import("aegis");
const std = @import("std");
const Locks = aegis.Order(&.{.{ .name = "count" }});
const Counter = Locks.Ordered(aegis.BlockingGuarded(u32), 0);
pub fn bump(io: std.Io, context: *Locks.Context, g: *Counter, n: u8) !void {
    const held, const other = .{ g, n };
    _ = other;
    var guard = try held.acquireOrdered(io, context);
    defer guard.deinit(io);
    guard.value().* += 1;
}
