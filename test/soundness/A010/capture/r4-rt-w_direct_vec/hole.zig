// review 4: rt/w_direct_vec.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u32 {
    var x: u32 = 0;
    const outs = [_]*u32{&x};
    for (outs) |o| o.* = try r.takeInt(u32, .little);
    return x + 1;
}
