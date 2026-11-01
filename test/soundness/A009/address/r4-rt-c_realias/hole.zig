// review 4: rt/c_realias.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u8 {
    var big: [512]u8 = undefined;
    var small: [16]u8 = @splat(0);
    var b: []u8 = big[0..];
    const n = try r.readSliceShort(b);
    b = small[0..];
    return b[0..n][0];
}
