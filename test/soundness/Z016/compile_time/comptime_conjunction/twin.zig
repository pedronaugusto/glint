// twin
const std = @import("std");
pub fn check(comptime a: bool, comptime b: bool) void {
    std.debug.assert(comptime a);
    std.debug.assert(comptime b);
}
