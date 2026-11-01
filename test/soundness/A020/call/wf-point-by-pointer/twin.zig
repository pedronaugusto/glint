// warp-fast: the same loop whose pointer's every store is a cancellation point
const std = @import("std");
fn wait(io: std.Io) !void {
    try io.checkCancel();
}
fn nap(io: std.Io) !void {
    try io.checkCancel();
}
pub fn spin(io: std.Io, fast: bool) !void {
    var pause: *const fn (std.Io) anyerror!void = &wait;
    if (fast) pause = &nap;
    while (true) try pause(io);
}
