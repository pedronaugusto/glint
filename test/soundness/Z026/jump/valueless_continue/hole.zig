// Z026: the handler is a continue with no operand
fn fallible() error{Failure}!void {
    return error.Failure;
}
pub fn run(n: u32) void {
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        fallible() catch continue;
    }
}
