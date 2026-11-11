// Z016: std assert of a conjunction a constant holds
const std = @import("std");
pub fn check(a: bool, b: bool) void {
    const both = a and b;
    std.debug.assert(both);
}
