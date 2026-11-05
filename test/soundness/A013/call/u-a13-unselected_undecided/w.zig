// An import of the case's, not selected: one function asserts through std.debug.assert held in a field, one asserts nothing.
const std = @import("std");
const Check = struct { f: *const fn (bool) void };
pub fn check(n: u8) void {
    var t: Check = .{ .f = &std.debug.assert };
    _ = &t;
    t.f(n < 10);
}
pub fn plain(n: u8) u8 {
    return n;
}
