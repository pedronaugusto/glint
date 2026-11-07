// matrix: Z026 deferred: an errdefer's cleanup unwrapped by if, its error captured by _ and dropped. Clean by
// the book's ruling (11-07): an errdefer runs as an error leaves, the one reported, and the cleanup's own can
// only be dropped or made a panic.
fn fallible() error{Failure}!void {
    return error.Failure;
}
pub fn run() !void {
    errdefer if (fallible()) {} else |_| {};
    try fallible();
}
