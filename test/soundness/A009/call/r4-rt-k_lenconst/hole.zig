// review 4: rt/k_lenconst.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader, big: []u8, c: bool) !u8 {
    var s: []u8 = big;
    const len = s.len;
    const i: usize = try r.takeInt(u32, .little);
    if (c) s = s[0..1];
    if (i >= len) return error.Bad;
    return s[i];
}
