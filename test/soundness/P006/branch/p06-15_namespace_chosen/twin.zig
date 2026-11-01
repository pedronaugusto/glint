// P006 branch: a namespace an if chooses; the allowed std.debug.assert is reached
const std = @import("std");

pub fn f() void {
    const d = if (@import("builtin").is_test) std.debug else std.debug;
    d.assert(true);
}
