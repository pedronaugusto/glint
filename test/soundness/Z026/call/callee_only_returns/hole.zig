// Z026: the handler calls a function that does nothing but return
fn fallible() error{Failure}!void {
    return error.Failure;
}
var failures: u32 = 0;
fn noop() void {
    return;
}
pub fn run() void {
    fallible() catch noop();
}
