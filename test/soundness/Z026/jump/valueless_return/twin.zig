// Z026 twin: the handler counts the error, then returns
fn fallible() error{Failure}!void {
    return error.Failure;
}
var failures: u32 = 0;
pub fn run() void {
    fallible() catch {
        failures += 1;
        return;
    };
}
