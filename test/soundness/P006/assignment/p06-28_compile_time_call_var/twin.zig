// P006 assignment: a var in a function called only at compile time holding a pointer type and
// given another: nothing disallowed is reached
fn g() usize {
    var X = []const u8;
    X = []const u16;
    return @sizeOf(X);
}
pub fn f() usize {
    return comptime g();
}
