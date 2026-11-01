// P006 compile_time: a member named by a constant; the disallowed std.debug.print is reached
const std = @import("std");

pub fn f() void {
    const name = "print";
    @field(std.debug, name)("x", .{});
}
