// review 5: a09/d01b_assign_bound.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader, out: *u64) !void {
    var n: u64 = 0;
    var i: u64 = 0;
    n = try r.takeInt(u64, .little);
    while (i < n) : (i += 1) out.* +%= i;
}
