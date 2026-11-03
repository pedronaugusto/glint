// pre-sweep-2 A013 twin: the same, called on what no input reaches.
const std = @import("std");
const check = std.debug.assert;
fn other(b: bool) void {
    _ = b;
}
const table = [_]*const fn (bool) void{ &check, &other };
pub fn f(r: *std.Io.Reader, n: u8) !u8 {
    const line = try r.take(4);
    table[n & 1](n > 3);
    return line[0];
}
