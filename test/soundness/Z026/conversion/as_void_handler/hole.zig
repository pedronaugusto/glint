// Z026: an empty handler spelled @as(void, {})
fn fallible() error{Failure}!void {
    return error.Failure;
}
var failures: u32 = 0;
pub fn run() void {
    fallible() catch @as(void, {});
}
