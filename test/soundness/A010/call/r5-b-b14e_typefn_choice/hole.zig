// review 5: b/b14e_typefn_choice.zig
const std = @import("std");
const Small = struct {
    pub const n = 4;
};
const Large = struct {
    pub const n = 64;
};
fn Pick(comptime wide: bool) type {
    return if (wide) Large else Small;
}
pub fn g(comptime wide: bool, x: u64) u64 {
    const T = Pick(wide);
    if (x >= T.n) return 0;
    return x * (1 << 59);
}
pub fn f(r: *std.Io.Reader) !u64 {
    const x: u64 = try r.takeInt(u64, .little);
    return g(false, x) + g(true, x);
}
