// matrix: Z026 deferred: an errdefer's cleanup unwrapped by if, its error captured by _ and dropped
fn fallible() error{Failure}!void {
    return error.Failure;
}
pub fn run() !void {
    errdefer if (fallible()) {} else |_| {};
    try fallible();
}
