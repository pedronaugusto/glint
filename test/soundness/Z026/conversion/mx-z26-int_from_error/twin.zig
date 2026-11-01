// matrix: Z026 conversion: an error caught, converted by @intFromError and the number kept
fn fallible() error{Failure}!void {
    return error.Failure;
}
var last: u16 = 0;
pub fn run() void {
    fallible() catch |err| {
        last = @intFromError(err);
    };
}
