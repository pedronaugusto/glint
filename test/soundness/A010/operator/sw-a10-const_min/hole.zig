// A010: @min of a u8 and a u64 is a u8: the peer's 255 plus one overflows it
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u64 {
    const a = try r.takeByte();
    const b = try r.takeInt(u64, .little);
    const i = @min(a, b);
    return i + 1;
}
