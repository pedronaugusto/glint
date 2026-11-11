// Z026 twin: the handler counts the error, then breaks
fn fallible() error{Failure}!void {
    return error.Failure;
}
var failures: u32 = 0;
pub fn run(n: usize) void {
    for (0..n) |_| {
        fallible() catch {
            failures += 1;
            break;
        };
    }
}
