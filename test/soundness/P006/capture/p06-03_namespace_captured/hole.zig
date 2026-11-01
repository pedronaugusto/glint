// P006 capture: a namespace captured from an optional; the disallowed std.debug.print is reached
const std = @import("std");

pub fn f() void {
    const opt: ?type = std.debug;
    if (opt) |d| d.print("x", .{});
}
