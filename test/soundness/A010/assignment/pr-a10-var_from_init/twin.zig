// precision A010 assignment: a variable spelled with no type is its initializer's, so a position checked below a length steps past it within its type
const std = @import("std");
pub fn f(r: *std.Io.Reader, buf: []const u8) !u64 {
    const n = try r.takeInt(u64, .little);
    var i = n | 1;
    if (i < buf.len) i += 1;
    return i;
}
