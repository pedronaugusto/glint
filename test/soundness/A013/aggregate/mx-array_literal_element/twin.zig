// matrix: input put into an array literal, the element then refused by an error
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u8 {
    const pair = [_]u8{ try r.takeByte(), 0 };
    if (pair[0] >= 4) return error.Bad;
    return pair[0];
}
