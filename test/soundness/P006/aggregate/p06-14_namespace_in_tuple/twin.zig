// P006 aggregate: a namespace an element of a tuple holds; the allowed std.debug.assert is reached
const std = @import("std");

pub fn f() void {
    const t = .{std.debug};
    t[0].assert(true);
}
