// A021: an ordered lock's pointer the result of a labeled block, its ranked acquisition: none.
const aegis = @import("aegis");
const std = @import("std");
const Locks = aegis.Order(&.{.{ .name = "count" }});
const Counter = Locks.Ordered(aegis.BlockingGuarded(u32), 0);
pub fn bump(io: std.Io, context: *Locks.Context, g: *Counter) !void {
    const held = blk: {
        break :blk g;
    };
    var guard = try held.acquireOrdered(io, context);
    defer guard.deinit(io);
    guard.value().* += 1;
}
