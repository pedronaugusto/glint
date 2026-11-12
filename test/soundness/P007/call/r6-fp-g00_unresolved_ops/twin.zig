// review 6: fp/g00_unresolved_ops.zig
const std = @import("std");
pub const Ops = struct { step: *const fn (std.Io) anyerror!void };
// Baseline: the step comes from the caller, nothing shows it a cancellation point.
pub fn spin(io: std.Io, ops: Ops, r: *std.Io.Reader) !void {
    const n: usize = try r.takeInt(u32, .little);
    var i: usize = 0;
    while (i < n) : (i += 1) try ops.step(io);
}
