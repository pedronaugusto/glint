// Z026: the handler is an if whose branches are both empty
fn fallible() error{Failure}!void {
    return error.Failure;
}
var failures: u32 = 0;
pub fn run(c: bool) void {
    fallible() catch if (c) {} else {};
}
