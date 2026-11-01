// matrix: Z026 branch: an error caught and switched on, its prong answering it
fn fallible() error{Failure}!void {
    return error.Failure;
}
var failures: u32 = 0;
pub fn run() void {
    fallible() catch |err| switch (err) {
        error.Failure => failures += 1,
    };
}
