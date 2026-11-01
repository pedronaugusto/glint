// P006 conversion: a namespace through @as; the allowed std.debug.assert is reached
const std = @import("std");

pub fn f() void {
    const d = @as(type, std.debug);
    d.assert(true);
}
