// matrix: Z026 unwrap: an error union unwrapped by catch with a handler that answers it
fn fallible() error{Failure}!void {
    return error.Failure;
}
var failures: u32 = 0;
pub fn run() void {
    fallible() catch {
        failures += 1;
    };
}
