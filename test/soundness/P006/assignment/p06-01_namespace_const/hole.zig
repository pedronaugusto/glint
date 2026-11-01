// P006 assignment: a namespace held in a constant, its member called; the disallowed std.debug.print is reached
const std = @import("std");

pub fn f() void {
    const d = std.debug;
    d.print("x", .{});
}
