// A021: a ranked acquisition at the scope's end: none.
const aegis = @import("aegis");
const std = @import("std");
const Locks = aegis.Order(&.{.{ .name = "count" }});
const Counter = Locks.Ordered(aegis.BlockingGuarded(u32), 0);
pub fn finish(io: std.Io, context: *Locks.Context, held: *Counter) void {
    defer {
        var guard = held.acquireOrderedUncancelable(io, context);
        defer guard.deinit(io);
        guard.value().* += 1;
    }
}
