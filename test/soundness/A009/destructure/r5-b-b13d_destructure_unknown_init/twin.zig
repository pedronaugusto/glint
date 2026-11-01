// review 5: b/b13d_destructure_unknown_init.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader, start: u64) !u64 {
    var v: u64 = start;
    const n: u64 = try r.takeInt(u64, .little);
    v, _ = .{ n, 0 };
    return v * 1000;
}
