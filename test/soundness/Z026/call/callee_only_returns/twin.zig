// twin
fn fallible() error{Failure}!void {
    return error.Failure;
}
var failures: u32 = 0;
fn note() void {
    failures += 1;
}
pub fn run() void {
    fallible() catch note();
}
