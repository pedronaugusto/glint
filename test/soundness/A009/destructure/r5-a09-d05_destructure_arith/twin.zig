// review 5: a09/d05_destructure_arith.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u64 {
    var n: u64 = undefined;
    var i: u64 = undefined;
    n, i = .{ try r.takeInt(u64, .little), 0 };
    const m = n;
    return m * m + i;
}
