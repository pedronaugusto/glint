// matrix: Z026 capture: an error union unwrapped by if, its error captured and counted
fn fallible() error{Failure}!void {
    return error.Failure;
}
var last: ?anyerror = null;
pub fn run() void {
    if (fallible()) {} else |err| {
        last = err;
    }
}
