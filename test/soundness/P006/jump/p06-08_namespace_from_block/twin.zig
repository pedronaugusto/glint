// P006 jump: a namespace a labeled block breaks with; the allowed std.debug.assert is reached
const std = @import("std");

pub fn f() void {
    const d = blk: {
        break :blk std.debug;
    };
    d.assert(true);
}
