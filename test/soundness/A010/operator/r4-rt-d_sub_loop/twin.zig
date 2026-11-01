// review 4: rt/d_sub_loop.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u32 {
    const a = try r.takeInt(u32, .little);
    var b = try r.takeInt(u32, .little);
    var total: u32 = 0;
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        if (b > a) return error.Bad;
        total +%= a - b;
        b = try r.takeInt(u32, .little);
    }
    return total;
}
