// P006 compile_time: a member named by a constant; the allowed std.debug.assert is reached
const std = @import("std");

pub fn f() void {
    const name = "assert";
    @field(std.debug, name)(true);
}
