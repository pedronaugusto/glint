// review 5: b/b22b_choice_array_builtin.zig
const std = @import("std");
const builtin = @import("builtin");
const Small = struct {
    pub const n = 4;
};
const Large = struct {
    pub const n = 64;
};
const T = if (builtin.mode == .Debug) Large else Small;
pub fn f(r: *std.Io.Reader) !u8 {
    const buf: [T.n]u8 = @splat(0);
    const i: usize = try r.takeInt(u32, .little);
    if (i >= 64) return 0;
    return buf[i];
}
