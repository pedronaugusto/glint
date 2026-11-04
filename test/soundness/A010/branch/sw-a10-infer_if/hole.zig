// A010: the variable is of the peer type of both branches, u16, which the peer's 65535 plus one overflows
const std = @import("std");
pub fn f(r: *std.Io.Reader, c: bool) !u64 {
    const a = try r.takeByte();
    const b = try r.takeInt(u16, .little);
    var i = if (c) a else b;
    i += 1;
    return i;
}
