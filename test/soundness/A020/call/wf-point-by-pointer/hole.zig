// warp-fast: a loop with no bound whose only call is through a pointer one of whose stores never cancels
const std = @import("std");
fn wait(io: std.Io) !void {
    try io.checkCancel();
}
fn idle(io: std.Io) !void {
    _ = io;
}
pub fn spin(io: std.Io, fast: bool) !void {
    var pause: *const fn (std.Io) anyerror!void = &wait;
    if (fast) pause = &idle;
    while (true) try pause(io);
}
