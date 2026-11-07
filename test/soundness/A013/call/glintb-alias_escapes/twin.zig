// glint-b: std's assert aliased and called through the alias on what no input reaches: every call through it is known
const std = @import("std");
const check = std.debug.assert;
pub fn f(r: *std.Io.Reader, n: u8) !u8 {
    const line = try r.take(4);
    check(n > 3);
    return line[0];
}
