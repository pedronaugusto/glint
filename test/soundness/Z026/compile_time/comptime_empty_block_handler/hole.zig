// Z026: a handler whose one statement is an empty comptime block, the error dropped
fn fallible() error{Failure}!void {
    return error.Failure;
}
pub fn run() void {
    fallible() catch {
        comptime {}
    };
}
