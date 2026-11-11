// Z026 twin: the empty catch is written inside the test block
fn fallible() error{Failure}!void {
    return error.Failure;
}
test "fallible fails" {
    fallible() catch {};
}
