// review 4: rt/d_sub_or.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader, c: bool) !u32 {
    const a = try r.takeInt(u32, .little);
    const b = try r.takeInt(u32, .little);
    if (c or b > a) {} else return a - b;
    return a - b;
}
