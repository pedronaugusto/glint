// review 4: rt/f_bitcast.zig
const std = @import("std");
const S = packed struct { lo: u32, hi: u32 };
pub fn f(r: *std.Io.Reader) !u64 {
    const v: S = .{ .lo = try r.takeInt(u32, .little), .hi = try r.takeInt(u32, .little) };
    const raw: u64 = @bitCast(v);
    return raw + 1;
}
