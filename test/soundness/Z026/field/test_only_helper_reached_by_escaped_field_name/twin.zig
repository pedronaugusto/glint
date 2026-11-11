// twin: the helper production reaches counts its error
fn fallible() error{Invalid}!void {
    return error.Invalid;
}
var failures: u32 = 0;
fn helper() void {
    fallible() catch {
        failures += 1;
    };
}
pub fn run() void {
    @field(@This(), "he\x6cper")();
}
test helper {
    helper();
}
