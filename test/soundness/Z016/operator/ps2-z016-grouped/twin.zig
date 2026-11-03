const std = @import("std");
pub fn check(a: u8, b: u8) void {
    std.debug.assert(a > 1);
    std.debug.assert(b > 1);
}
