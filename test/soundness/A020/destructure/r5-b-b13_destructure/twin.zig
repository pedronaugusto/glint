// review 5: b/b13_destructure.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u64 {
    var v: u64 = 5;
    const n: u64 = try r.takeInt(u64, .little);
    v, _ = .{ n, 0 };
    return v * 1000;
}
