// Z026: an errdefer's cleanup unwrapped by if, its error captured by _ and dropped: the handler is empty
// wherever it runs.
fn fallible() error{Failure}!void {
    return error.Failure;
}
pub fn run() !void {
    errdefer if (fallible()) {} else |_| {};
    try fallible();
}
