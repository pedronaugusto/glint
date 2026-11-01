// matrix: Z026 capture: an error union unwrapped by if, its error captured by _ and its branch empty
fn fallible() error{Failure}!void {
    return error.Failure;
}
pub fn run() void {
    if (fallible()) {} else |_| {}
}
