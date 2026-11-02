// The same pointer called on what no input reaches.
const std = @import("std");
const check: *const fn (bool) void = &std.debug.assert;
pub fn f(r: *std.Io.Reader, n: u8) !u8 {
    const line = try r.take(4);
    check(n > 3);
    return line[0];
}
