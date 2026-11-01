// review 5: b/h04_three_lengths.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader, a: []const u8, b: []const u8, c: []const u8) !usize {
    const n: usize = try r.takeInt(u64, .little);
    if (n > a.len) return 0;
    return n + b.len + c.len;
}
