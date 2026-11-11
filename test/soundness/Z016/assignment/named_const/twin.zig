// twin
const std = @import("std");
pub fn check(a: bool, b: bool) void {
    const first = a;
    std.debug.assert(first);
    std.debug.assert(b);
}
