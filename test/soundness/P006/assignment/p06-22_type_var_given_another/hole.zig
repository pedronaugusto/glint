// P006 assignment: a comptime var holding one type, given another (std.Io), its member read
// after: the disallowed std.Io.async is reached
const S = struct { async: u8 };
pub fn f() void {
    comptime var X: type = S;
    X = @import("std").Io;
    _ = X.async;
}
