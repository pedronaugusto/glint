const std = @import("std");
pub fn f(r: *std.Io.Reader, c: bool) !u64 {
    const a = try r.takeByte();
    const b = try r.takeInt(u16, .little);
    var i: u32 = if (c) a else b;
    i += 1;
    return i;
}
