// review 4: rt/s_count.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u8 {
    const input = try r.take(64);
    var small: [16]u8 = @splat(0);
    _ = &small;
    const n = std.mem.count(u8, input, "a");
    return small[n];
}
