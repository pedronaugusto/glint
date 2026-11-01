// review 6: ud/v04_unresolved_method.zig
const std = @import("std");
const ext = @import("missing");
// A call that does not resolve, given the local's address.
pub fn f() u8 {
    var w: [4]u8 = .{ 1, 2, 3, 4 };
    ext.free(&w);
    return w[0];
}
