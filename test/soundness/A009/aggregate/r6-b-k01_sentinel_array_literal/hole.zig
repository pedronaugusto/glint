// review 6: b/k01_sentinel_array_literal.zig
const std = @import("std");
// `[_:0]u8{...}` has a sentinel: z[z.len] is a valid read, so the then-branch is live and i is unchecked there.
pub fn f(r: *std.Io.Reader, c: bool, table: *const [16]u8) !u8 {
    const i: usize = try r.takeInt(u32, .little);
    const z = [_:0]u8{ 1, 2, 3 };
    var acc: u8 = 0;
    if (c) {
        acc = z[z.len];
    } else {
        if (i >= 16) return 0;
    }
    return acc +% table[i];
}
