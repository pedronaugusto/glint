// Z026: a handler that yields undefined: the error is discarded and the value is garbage.
fn f() !u32 {
    return 1;
}
pub fn g() u32 {
    return f() catch undefined;
}
