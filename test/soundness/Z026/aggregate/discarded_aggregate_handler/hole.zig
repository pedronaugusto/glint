// Z026: the handler puts the error's number into an aggregate nobody takes
fn fallible() error{Failure}!void {
    return error.Failure;
}
var failures: u32 = 0;
pub fn run() void {
    fallible() catch |err| {
        _ = .{@intFromError(err)};
    };
}
