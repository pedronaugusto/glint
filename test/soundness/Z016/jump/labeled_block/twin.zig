// twin
const std = @import("std");
pub fn check(a: bool, b: bool) void {
    std.debug.assert(blk: {
        break :blk a;
    });
    std.debug.assert(b);
}
