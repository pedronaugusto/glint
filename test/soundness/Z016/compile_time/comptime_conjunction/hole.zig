// Z016: std assert of a conjunction written under `comptime`
const std = @import("std");
pub fn check(comptime a: bool, comptime b: bool) void {
    std.debug.assert(comptime a and b);
}
