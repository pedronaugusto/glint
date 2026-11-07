// matrix: Z026 deferred: the same cleanup in a plain defer, which runs on success too: its error dropped is a
// failure nobody reads.
fn fallible() error{Failure}!void {
    return error.Failure;
}
pub fn run() !void {
    defer if (fallible()) {} else |_| {};
    try fallible();
}
