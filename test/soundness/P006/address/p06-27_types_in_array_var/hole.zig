// P006 address: a var holding an array of types, its element given std.Io
const S = struct {
    pub const x = 1;
};
pub fn f() void {
    comptime var ts = [_]type{S};
    ts[0] = @import("std").Io;
    _ = ts[0].async;
}
