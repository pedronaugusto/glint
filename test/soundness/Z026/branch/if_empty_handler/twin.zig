// twin
fn fallible() error{Failure}!void {
    return error.Failure;
}
var failures: u32 = 0;
pub fn run(c: bool) void {
    fallible() catch if (c) {
        failures += 1;
    } else {
        failures += 2;
    };
}
