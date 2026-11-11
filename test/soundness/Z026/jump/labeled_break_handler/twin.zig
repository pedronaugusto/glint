// twin: the handler answers
fn fallible() error{Failure}!void {
    return error.Failure;
}
var failures: u32 = 0;
pub fn run() void {
    fallible() catch {
        failures += 1;
    };
}
