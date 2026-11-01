// review 6: fp/g03_pub_type_consumer.zig
const std = @import("std");
// A public type with a public field: a consumer may build Ops with any step. The one literal here cancels.
pub const Ops = struct { step: *const fn (std.Io) anyerror!void };
fn tick(io: std.Io) anyerror!void {
    try io.checkCancel();
}
pub const default: Ops = .{ .step = tick };
pub fn spin(io: std.Io, ops: Ops, r: *std.Io.Reader) !void {
    const n: usize = try r.takeInt(u32, .little);
    var i: usize = 0;
    while (i < n) : (i += 1) try ops.step(io);
}
