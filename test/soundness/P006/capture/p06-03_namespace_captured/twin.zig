// P006 capture: a namespace captured from an optional; the allowed std.debug.assert is reached
const std = @import("std");

pub fn f() void {
    const opt: ?type = std.debug;
    if (opt) |d| d.assert(true);
}
