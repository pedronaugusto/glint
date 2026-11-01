// review 6: b/k03_ptr_to_sentinel_slice.zig
const std = @import("std");
// `z.*` of a pointer to a sentinel slice.
pub fn f(r: *std.Io.Reader, zp: *const [:0]const u8, c: bool, table: *const [16]u8) !u8 {
    const i: usize = try r.takeInt(u32, .little);
    var acc: u8 = 0;
    if (c) {
        acc = zp.*[zp.len];
    } else {
        if (i >= 16) return 0;
    }
    return acc +% table[i];
}
