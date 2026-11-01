// matrix: input put into an array literal, the element then asserted
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u8 {
    const pair = [_]u8{ try r.takeByte(), 0 };
    std.debug.assert(pair[0] < 4);
    return pair[0];
}
