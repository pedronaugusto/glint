// Z026: catch unreachable, a panic or undefined behaviour in ReleaseFast where the error comes
fn fallible() error{Failure}!void {
    return error.Failure;
}
pub fn run() void {
    fallible() catch unreachable;
}
