// review 6: a20/e03_generic_ctx.zig
const std = @import("std");
pub fn spin(comptime T: type, ctx: T, r: *std.Io.Reader) !u64 {
    const n: u64 = try r.takeInt(u64, .little);
    var t: u64 = 0;
    var i: u64 = 0;
    while (i < n) : (i += 1) t +%= i;
    _ = ctx;
    return t;
}
const Ctx = struct { io: std.Io };
pub fn run(io: std.Io, r: *std.Io.Reader) !u64 {
    return spin(Ctx, .{ .io = io }, r);
}
