// review 4: rt/s_other.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u8 {
    const input = try r.take(64);
    var small: [16]u8 = @splat(0);
    _ = &small;
    const pos = std.mem.findScalar(u8, input, 0) orelse return error.Bad;
    return small[pos];
}
