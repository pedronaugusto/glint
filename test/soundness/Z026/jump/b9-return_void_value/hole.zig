// Z026: a handler that returns the void value, a bare return written with an operand: the error
// is discarded with no reason.
const std = @import("std");
fn f() !void {}
pub fn g() void {
    f() catch return {};
}
