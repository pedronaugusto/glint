// Z026: the handler is a return with no operand
fn fallible() error{Failure}!void {
    return error.Failure;
}
pub fn run() void {
    fallible() catch return;
}
