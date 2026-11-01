// review 4: rt/i_sum32.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader, buf: []const u8) !usize {
    const n: u32 = try r.takeInt(u32, .little);
    return buf.len + n;
}
