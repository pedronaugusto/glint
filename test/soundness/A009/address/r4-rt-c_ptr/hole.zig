// review 4: rt/c_ptr.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader, other: *[512]u8) !u8 {
    var big: [512]u8 = undefined;
    const p = &big;
    const n = try r.readSliceShort(p);
    return p[0..n][0] +% other[0];
}
pub fn g(r: *std.Io.Reader, buf: []u8, small: []u8) !u8 {
    const n = try r.readSliceShort(buf);
    return small[0..n][0];
}
