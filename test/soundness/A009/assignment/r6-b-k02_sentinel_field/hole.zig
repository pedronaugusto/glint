// review 6: b/k02_sentinel_field.zig
const std = @import("std");
// A sentinel slice reached through a struct field with no type written at the local.
const H = struct { z: [:0]const u8 };
pub fn f(r: *std.Io.Reader, h: H, c: bool, table: *const [16]u8) !u8 {
    const i: usize = try r.takeInt(u32, .little);
    const z = h.z;
    var acc: u8 = 0;
    if (c) {
        acc = z[z.len];
    } else {
        if (i >= 16) return 0;
    }
    return acc +% table[i];
}
