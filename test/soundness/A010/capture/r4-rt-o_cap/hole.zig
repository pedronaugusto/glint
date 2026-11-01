// review 4: rt/o_cap.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u32 {
    const v: ?u32 = try r.takeInt(u32, .little);
    if (v) |x| return x + 1;
    return 0;
}
