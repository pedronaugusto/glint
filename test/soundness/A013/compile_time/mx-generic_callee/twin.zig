// matrix: a generic helper, its type a comptime parameter, asserts what the program computes as it compiles
const std = @import("std");
fn below(comptime T: type, comptime v: T, limit: T) T {
    comptime std.debug.assert(v < 4);
    return if (v < limit) v else limit;
}
pub fn f(r: *std.Io.Reader) !u8 {
    return below(u8, 3, try r.takeByte());
}
