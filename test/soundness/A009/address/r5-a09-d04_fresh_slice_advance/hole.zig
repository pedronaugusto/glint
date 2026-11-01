// review 5: a09/d04_fresh_slice_advance.zig
const std = @import("std");
// The slice advanced each pass is made afresh each pass: it bounds nothing.
pub fn f(r: *std.Io.Reader, whole: []const u8, out: *u64) !void {
    const n = try r.takeInt(u64, .little);
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        var cp = whole;
        cp = cp[1..];
        out.* +%= cp.len;
    }
}
