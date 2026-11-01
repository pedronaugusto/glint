// review 5: b/b22c_plain_base.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u8 {
    const buf: [4]u8 = @splat(0);
    const i: usize = try r.takeInt(u32, .little);
    if (i >= 64) return 0;
    return buf[i];
}
