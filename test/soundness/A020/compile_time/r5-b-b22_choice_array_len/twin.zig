// review 5: b/b22_choice_array_len.zig
const std = @import("std");
const Small = struct {
    pub const n = 4;
};
const Large = struct {
    pub const n = 64;
};
fn Type(comptime wide: bool) type {
    return if (wide) Large else Small;
}
pub fn g(comptime wide: bool, r: *std.Io.Reader) !u8 {
    const buf: [Type(wide).n]u8 = @splat(0);
    const i: usize = try r.takeInt(u32, .little);
    if (i >= 64) return 0;
    return buf[i];
}
pub fn f(r: *std.Io.Reader) !u8 {
    return try g(false, r) +% try g(true, r);
}
