// Z026: the handler is a break with no operand
fn fallible() error{Failure}!void {
    return error.Failure;
}
pub fn run(n: usize) void {
    for (0..n) |_| {
        fallible() catch break;
    }
}
