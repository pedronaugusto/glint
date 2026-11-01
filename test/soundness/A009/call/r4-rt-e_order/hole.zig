// review 4: rt/e_order.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader, buf: []const u8) ![]const u8 {
    const i: usize = try r.takeInt(u32, .little);
    const n: usize = try r.takeInt(u32, .little);
    if (i > buf.len) return error.Bad;
    if (n > buf.len) return error.Bad;
    return buf[i..n];
}
