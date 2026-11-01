// review 6: b/k01c_sentinel_alias_literal.zig
const std = @import("std");
const Z = [3:0]u8;
pub fn f(r: *std.Io.Reader, c: bool, table: *const [16]u8) !u8 {
    const i: usize = try r.takeInt(u32, .little);
    const z = Z{ 1, 2, 3 };
    var acc: u8 = 0;
    if (c) {
        acc = z[z.len];
    } else {
        if (i >= 16) return 0;
    }
    return acc +% table[i];
}
