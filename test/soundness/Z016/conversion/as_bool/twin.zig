// twin
const std = @import("std");
pub fn check(a: bool, b: bool) void {
    std.debug.assert(@as(bool, a));
    std.debug.assert(b);
}
