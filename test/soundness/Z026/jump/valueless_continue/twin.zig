// Z026 twin: the handler counts the error, then continues
fn fallible() error{Failure}!void {
    return error.Failure;
}
var failures: u32 = 0;
pub fn run(n: u32) void {
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        fallible() catch {
            failures += 1;
            continue;
        };
    }
}
