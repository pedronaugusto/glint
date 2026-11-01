// matrix: Z026 deferred: a deferred cleanup whose error a handler answers
fn fallible() error{Failure}!void {
    return error.Failure;
}
var failures: u32 = 0;
pub fn run() void {
    defer fallible() catch {
        failures += 1;
    };
}
