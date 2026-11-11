// Z026: production reaches the private helper through @field with an escaped literal name,
// so the helper is no test-only function and its empty catch is a site.
fn fallible() error{Invalid}!void {
    return error.Invalid;
}
fn helper() void {
    fallible() catch {};
}
pub fn run() void {
    @field(@This(), "he\x6cper")();
}
test helper {
    helper();
}
