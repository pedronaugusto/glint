// review 6: fp/g01_seen_cancel.zig
const std = @import("std");
const Ops = struct { step: *const fn (std.Io) anyerror!void, n: u32 };
fn tick(io: std.Io) anyerror!void {
    try io.checkCancel();
}
var ops: Ops = .{ .step = tick, .n = 0 };
pub fn spin(io: std.Io, r: *std.Io.Reader) !void {
    const n: usize = try r.takeInt(u32, .little);
    var i: usize = 0;
    while (i < n) : (i += 1) try ops.step(io);
}
