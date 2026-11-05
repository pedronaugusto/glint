// An import of the case's, not selected: it asserts on what it is given.
const std = @import("std");
pub fn check(n: u8) void {
    std.debug.assert(n < 10);
}
