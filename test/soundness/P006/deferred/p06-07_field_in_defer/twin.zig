// P006 deferred: a member named by @field in a defer; the allowed std.debug.assert is reached
const std = @import("std");

pub fn f() void {
    defer @field(std.debug, "assert")(true);
}
