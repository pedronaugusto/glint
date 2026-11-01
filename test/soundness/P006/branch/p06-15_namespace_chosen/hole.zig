// P006 branch: a namespace an if chooses; the disallowed std.debug.print is reached
const std = @import("std");

pub fn f() void {
    const d = if (@import("builtin").is_test) std.debug else std.debug;
    d.print("x", .{});
}
