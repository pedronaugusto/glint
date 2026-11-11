// A013: unreachable right after a guard on a peer's byte that returns: reached exactly when the byte is not ':'
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u8 {
    const b = try r.takeByte();
    if (b == ':') return b;
    unreachable;
}
