// Z026 twin: the defer counts the error as the handler ends
fn fallible() error{Failure}!void {
    return error.Failure;
}
var failures: u32 = 0;
pub fn run() void {
    fallible() catch {
        defer failures += 1;
    };
}
