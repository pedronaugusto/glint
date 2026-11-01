// review 5: a09/d06b_read.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader, out: *u64) !void {
    const n = try r.takeInt(u64, .little);
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        out.* +%= try r.takeByte();
    }
}
