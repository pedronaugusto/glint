// P006 conversion: a namespace through @as; the disallowed std.debug.print is reached
const std = @import("std");

pub fn f() void {
    const d = @as(type, std.debug);
    d.print("x", .{});
}
