// P006 address: a namespace reached through a pointer to it; the disallowed std.debug.print is reached
const std = @import("std");

pub fn f() void {
    const p = &std.debug;
    p.*.print("x", .{});
}
