// review 5: a09/d01_destructure_bound.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader, out: *u64) !void {
    var n: u64 = 0;
    var i: u64 = 0;
    n, i = .{ try r.takeInt(u64, .little), 0 };
    while (i < n) : (i += 1) out.* +%= i;
}
