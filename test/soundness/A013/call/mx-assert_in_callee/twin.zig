// matrix: input handed to a helper that refuses a bad one by an error
const std = @import("std");
fn checked(kind: u8) !u8 {
    if (kind >= 4) return error.Bad;
    return kind;
}
pub fn f(r: *std.Io.Reader) !u8 {
    return checked(try r.takeByte());
}
