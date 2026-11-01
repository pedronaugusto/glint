// matrix: Z026 call: an error caught and handed to a callee that drops it
fn fallible() error{Failure}!void {
    return error.Failure;
}
fn ignore(_: anyerror) void {}
pub fn run() void {
    fallible() catch |err| ignore(err);
}
