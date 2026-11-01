// review 5: b/b13c_destructure_untainted.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u64 {
    var v: u64 = 5;
    var w: u64 = 0;
    const n: u64 = try r.takeInt(u64, .little);
    v, w = .{ n, 0 };
    return v * 1000 + w;
}
