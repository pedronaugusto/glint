// P006 unwrap: a namespace unwrapped from an optional by .?; the allowed std.debug.assert is reached
const std = @import("std");

pub fn f() void {
    const opt: ?type = std.debug;
    opt.?.assert(true);
}
