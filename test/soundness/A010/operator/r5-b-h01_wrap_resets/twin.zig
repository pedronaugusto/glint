// review 5: b/h01_wrap_resets.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader, buf: []const u8) !u8 {
    const i: usize = try r.takeInt(u64, .little);
    if (i >= buf.len) return 0;
    const j = i +% std.math.maxInt(usize);
    return buf[j +% 2];
}
