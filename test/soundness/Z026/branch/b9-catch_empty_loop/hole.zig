// Z026: a handler that is a loop which never runs: the error is discarded with no reason.
fn f() !void {}
pub fn g() void {
    f() catch while (false) {};
}
