// Z026: a handler that returns the error it catches: nothing discarded.
const std = @import("std");
fn f() !void {}
pub fn g() !void {
    f() catch |err| return err;
}
