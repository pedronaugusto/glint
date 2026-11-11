// twin: the fall-through returns an error
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u8 {
    const b = try r.takeByte();
    if (b == ':') return b;
    return error.NotColon;
}
