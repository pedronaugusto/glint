// P006 call: a var given a slice type through @call, then std.Io
fn Id(comptime T: type) type {
    return T;
}
pub fn f() void {
    comptime var X = @call(.auto, Id, .{[]const u8});
    X = @import("std").Io;
    _ = X.async;
}
