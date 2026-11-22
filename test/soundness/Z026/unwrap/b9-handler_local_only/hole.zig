// Z026: a handler holding only a local and its discard: nothing reads the error.
fn f() !void {}
pub fn g() void {
    f() catch {
        const unused: u8 = 0;
        _ = unused;
    };
}
