// twin: a disjunction is one condition; splitting it changes what is asserted
const std = @import("std");
pub fn check(a: bool, b: bool) void {
    std.debug.assert(a or b);
}
