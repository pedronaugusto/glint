const std = @import("std");
pub fn f(r: *std.Io.Reader) !u64 {
    const b = try r.takeInt(u64, .little);
    var n: u64 = @min(b, 255);
    n += 1;
    return n;
}
