// review 5: b/b11_zst_len.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader, units: []const void) !usize {
    const n: usize = try r.takeInt(u64, .little);
    if (n > units.len) return error.Bad;
    return n + 1;
}
