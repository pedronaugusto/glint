// review 4: rt/d_sub_nodom.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader, c: bool) !u32 {
    const a = try r.takeInt(u32, .little);
    const b = try r.takeInt(u32, .little);
    if (c) {
        if (b > a) return error.Bad;
    }
    return a - b;
}
