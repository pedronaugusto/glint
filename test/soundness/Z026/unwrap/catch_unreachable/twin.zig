// Z026 twin: the error is returned
fn fallible() error{Failure}!void {
    return error.Failure;
}
pub fn run() !void {
    fallible() catch |err| return err;
}
