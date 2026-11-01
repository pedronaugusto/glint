// matrix: Z026 branch: an error caught and switched on, every error taken by an empty prong
fn fallible() error{Failure}!void {
    return error.Failure;
}
pub fn run() void {
    fallible() catch |err| switch (err) {
        else => {},
    };
}
