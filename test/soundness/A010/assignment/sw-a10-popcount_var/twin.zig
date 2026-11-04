const std = @import("std");
pub fn f(r: *std.Io.Reader) !u64 {
    const x = try r.takeInt(u64, .little);
    const y = try r.takeInt(u64, .little);
    var n: u64 = @popCount(x);
    n += @popCount(y);
    return n;
}
