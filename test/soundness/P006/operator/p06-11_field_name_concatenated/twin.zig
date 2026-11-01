// P006 operator: a member named by a concatenation; the allowed std.debug.assert is reached
const std = @import("std");

pub fn f() void {
    @field(std.debug, "as" ++ "sert")(true);
}
