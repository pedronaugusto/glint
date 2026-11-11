// twin: the argument as written is a negation, not `a and b`
const std = @import("std");
pub fn check(a: bool, b: bool) void {
    std.debug.assert(!(a and b));
}
