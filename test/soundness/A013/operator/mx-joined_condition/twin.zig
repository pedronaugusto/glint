// matrix: comparisons on input joined by and and negated, refused by an error
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u8 {
    const b = try r.takeByte();
    const ok = !(b > 3) and b != 2;
    if (!ok) return error.Bad;
    return b;
}
