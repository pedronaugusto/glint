// P006 deferred: a member named by @field in a defer; the disallowed std.debug.print is reached
const std = @import("std");

pub fn f() void {
    defer @field(std.debug, "print")("x", .{});
}
