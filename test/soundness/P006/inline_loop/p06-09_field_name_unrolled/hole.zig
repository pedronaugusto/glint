// P006 inline_loop: a member named by each pass of an inline for; the disallowed std.debug.print is reached
const std = @import("std");

pub fn f() void {
    inline for (.{"print"}) |name| @field(std.debug, name)("x", .{});
}
