// Z026: a handler that breaks its own label with the void value, a bare break written with an
// operand: the error is discarded with no reason.
const std = @import("std");
fn f() !void {}
pub fn g() void {
    f() catch blk: {
        break :blk {};
    };
}
