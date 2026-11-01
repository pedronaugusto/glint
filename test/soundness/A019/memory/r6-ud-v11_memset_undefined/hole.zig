// review 6: ud/v11_memset_undefined.zig
const std = @import("std");
fn wipe(d: []u8) void {
    @memset(d, undefined);
}
// A slice of the local handed on.
pub fn f() u8 {
    var w: [4]u8 = .{ 1, 2, 3, 4 };
    wipe(&w);
    return w[0];
}
