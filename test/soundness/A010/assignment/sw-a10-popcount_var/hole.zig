// A010: a variable a @popCount initializes is a u7; adding another word's count overflows it
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u64 {
    const x = try r.takeInt(u64, .little);
    const y = try r.takeInt(u64, .little);
    var n = @popCount(x);
    n += @popCount(y);
    return n;
}
