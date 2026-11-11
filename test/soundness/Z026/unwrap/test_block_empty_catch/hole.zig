// Z026: a private helper only a test calls is production code: its empty catch is a site
fn fallible() error{Failure}!void {
    return error.Failure;
}
fn helper() void {
    fallible() catch {};
}
test helper {
    helper();
}
