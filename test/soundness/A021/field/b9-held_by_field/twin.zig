// A021: an ordered lock a struct's field, its ranked acquisition through the field: none.
const aegis = @import("aegis");
const std = @import("std");
const Locks = aegis.Order(&.{.{ .name = "count" }});
const Counter = Locks.Ordered(aegis.BlockingGuarded(u32), 0);
pub const Stats = struct { count: Counter };
pub fn bump(io: std.Io, context: *Locks.Context, s: *Stats) !void {
    const held = &s.count;
    var guard = try held.acquireOrdered(io, context);
    defer guard.deinit(io);
    guard.value().* += 1;
}
