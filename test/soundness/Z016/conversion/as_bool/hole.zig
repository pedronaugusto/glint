// Z016: std assert of a conjunction, the argument wrapped in @as(bool, ...)
const std = @import("std");
pub fn check(a: bool, b: bool) void {
    std.debug.assert(@as(bool, a and b));
}
