// review 4: rt/d_sub_else.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u32 {
    const a = try r.takeInt(u32, .little);
    const b = try r.takeInt(u32, .little);
    if (b > a) {
        std.log.debug("big", .{});
    }
    return a - b;
}
