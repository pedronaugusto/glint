// review 5: a09/d04b_no_advance.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader, whole: []const u8, out: *u64) !void {
    const n = try r.takeInt(u64, .little);
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        const cp = whole;
        out.* +%= cp.len;
    }
}
