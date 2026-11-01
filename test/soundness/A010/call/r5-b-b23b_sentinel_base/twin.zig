// review 5: b/b23b_sentinel_base.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader, z: [:0]const u8, c: bool, table: *const [16]u8) !u8 {
    const i: usize = try r.takeInt(u32, .little);
    var acc: u8 = 0;
    if (c) {
        acc = z[0];
    } else {
        if (i >= 16) return 0;
    }
    return acc +% table[i];
}
