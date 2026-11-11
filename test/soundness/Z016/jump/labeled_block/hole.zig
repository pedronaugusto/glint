// Z016: std assert of a conjunction a labeled block gives
const std = @import("std");
pub fn check(a: bool, b: bool) void {
    std.debug.assert(blk: {
        break :blk a and b;
    });
}
