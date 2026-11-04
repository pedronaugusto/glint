const std = @import("std");
pub fn f(r: *std.Io.Reader) !u64 {
    const a = try r.takeByte();
    const b = try r.takeInt(u64, .little);
    var i: u64 = @min(a, b);
    i += 1;
    return i;
}
