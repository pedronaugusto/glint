// matrix: Z026 deferred: the same cleanup in a plain defer, its error counted
fn fallible() error{Failure}!void {
    return error.Failure;
}
var failures: u32 = 0;
pub fn run() !void {
    defer if (fallible()) {} else |_| {
        failures += 1;
    };
    try fallible();
}
