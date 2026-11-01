// matrix: Z026 conversion: an error caught, converted by @intFromError and the number discarded
fn fallible() error{Failure}!void {
    return error.Failure;
}
pub fn run() void {
    fallible() catch |err| {
        _ = @intFromError(err);
    };
}
