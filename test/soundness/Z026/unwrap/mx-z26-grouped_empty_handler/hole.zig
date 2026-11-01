// matrix: Z026 unwrap: an error union unwrapped by catch with an empty block in parentheses
fn fallible() error{Failure}!void {
    return error.Failure;
}
pub fn run() void {
    fallible() catch ({});
}
