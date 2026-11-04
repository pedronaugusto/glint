// P006 conversion: a var given a slice type through @as, then std.Io
pub fn f() void {
    comptime var X = @as(type, []const u8);
    X = @import("std").Io;
    _ = X.async;
}
