// matrix: input handed to a generic helper, its type a comptime parameter, that asserts it
const std = @import("std");
fn below(comptime T: type, v: T, limit: T) T {
    std.debug.assert(v < limit);
    return v;
}
pub fn f(r: *std.Io.Reader) !u8 {
    return below(u8, try r.takeByte(), 4);
}
