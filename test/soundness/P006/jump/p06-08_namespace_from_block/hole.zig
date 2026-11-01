// P006 jump: a namespace a labeled block breaks with; the disallowed std.debug.print is reached
const std = @import("std");

pub fn f() void {
    const d = blk: {
        break :blk std.debug;
    };
    d.print("x", .{});
}
