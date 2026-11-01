// matrix: input handed to a helper whose parameter it asserts
const std = @import("std");
fn checked(kind: u8) u8 {
    std.debug.assert(kind < 4);
    return kind;
}
pub fn f(r: *std.Io.Reader) !u8 {
    return checked(try r.takeByte());
}
