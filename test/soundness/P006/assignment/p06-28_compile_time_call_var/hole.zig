// P006 assignment: a var in a function called only at compile time, with no `comptime` of its
// own and a result other than `type`, holding a pointer type and given std.Io, its member read
// after: the disallowed std.Io.async is reached
fn g() usize {
    var X = []const u8;
    X = @import("std").Io;
    _ = X.async;
    return 0;
}
pub fn f() usize {
    return comptime g();
}
