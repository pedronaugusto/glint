// review 6: fp/g02_destructure_store_nocancel.zig
const std = @import("std");
const Ops = struct { step: *const fn (std.Io) anyerror!void, n: u32 };
fn tick(io: std.Io) anyerror!void {
    try io.checkCancel();
}
fn idle(io: std.Io) anyerror!void {
    _ = io;
}
var ops: Ops = .{ .step = tick, .n = 0 };
// A destructure stores idle, which is no cancellation point: the loop may run to its end.
pub fn quiet() void {
    ops.step, ops.n = .{ idle, 1 };
}
pub fn spin(io: std.Io, r: *std.Io.Reader) !void {
    const n: usize = try r.takeInt(u32, .little);
    var i: usize = 0;
    while (i < n) : (i += 1) try ops.step(io);
}
