// review 4: rt/k_branch.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader, big: []u8, c: bool) !u8 {
    var s: []u8 = big;
    const i: usize = try r.takeInt(u32, .little);
    if (i >= s.len) return error.Bad;
    if (c) s = s[0..1];
    return s[i];
}
