// matrix A007: the same exit setting an Io.Event, a signal that guards no data.
const std = @import("std");
pub fn release(io: std.Io, done: *std.Io.Event, n: *u32) void {
    defer done.set(io);
    n.* = 0;
}
