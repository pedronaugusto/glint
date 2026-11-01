// P006 inline_loop: a member named by each pass of an inline for; the allowed std.debug.assert is reached
const std = @import("std");

pub fn f() void {
    inline for (.{"assert"}) |name| @field(std.debug, name)(true);
}
