// review 4: rt/c_off.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u8 {
    var big: [512]u8 = undefined;
    const off: usize = 100;
    const n = try r.readSliceShort(big[off..]);
    return big[off + n];
}
