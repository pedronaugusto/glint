// P006 operator: a member named by a concatenation; the disallowed std.debug.print is reached
const std = @import("std");

pub fn f() void {
    @field(std.debug, "pr" ++ "int")("x", .{});
}
