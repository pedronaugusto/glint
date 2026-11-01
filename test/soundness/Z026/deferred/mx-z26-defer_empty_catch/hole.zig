// matrix: Z026 deferred: a deferred cleanup whose error an empty catch drops
fn fallible() error{Failure}!void {
    return error.Failure;
}
pub fn run() void {
    defer fallible() catch {};
}
