// precision A009 assignment: a variable spelled with no type is its initializer's, so its check below the memory's length holds where it indexes
const std = @import("std");
pub fn f(r: *std.Io.Reader, buf: []const u8) !u8 {
    const n = try r.takeInt(u64, .little);
    var i = n | 1;
    i |= 2;
    if (i >= buf.len) return 0;
    return buf[i];
}
