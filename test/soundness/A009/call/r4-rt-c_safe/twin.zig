// review 4: rt/c_safe.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u8 {
    var big: [512]u8 = undefined;
    const n = try r.readSliceShort(&big);
    return big[0..n][0];
}
