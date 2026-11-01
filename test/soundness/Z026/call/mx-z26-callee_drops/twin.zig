// matrix: Z026 call: an error caught and handed to a callee that keeps it
fn fallible() error{Failure}!void {
    return error.Failure;
}
var last: ?anyerror = null;
fn record(err: anyerror) void {
    last = err;
}
pub fn run() void {
    fallible() catch |err| record(err);
}
