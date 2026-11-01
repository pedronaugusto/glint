// review 4: rt/c_other.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u8 {
    var big: [512]u8 = undefined;
    var small: [16]u8 = @splat(0);
    const n = try r.readSliceShort(&big);
    return small[0..n][0] +% big[0];
}
