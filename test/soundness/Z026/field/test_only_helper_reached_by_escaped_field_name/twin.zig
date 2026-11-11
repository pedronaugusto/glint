// twin: only the test names the helper
fn fallible() error{Invalid}!void {
    return error.Invalid;
}
fn helper() void {
    fallible() catch {};
}
pub fn run() void {}
test helper {
    helper();
}
