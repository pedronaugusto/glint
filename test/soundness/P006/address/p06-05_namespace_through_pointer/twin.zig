// P006 address: a namespace reached through a pointer to it; the allowed std.debug.assert is reached
const std = @import("std");

pub fn f() void {
    const p = &std.debug;
    p.*.assert(true);
}
