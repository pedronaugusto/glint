// review 4: rt/i_mul.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader) !usize {
    const n: u16 = try r.takeInt(u16, .little);
    const m: u32 = try r.takeInt(u16, .little);
    return @as(u32, n) * m * 2;
}
