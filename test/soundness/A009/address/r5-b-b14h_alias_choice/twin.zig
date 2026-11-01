// review 5: b/b14h_alias_choice.zig
const std = @import("std");
const Small = struct {
    pub const n = 4;
};
const Large = struct {
    pub const n = 64;
};
fn Type(comptime wide: bool) type {
    if (wide) return Large;
    return Small;
}
pub fn g(comptime wide: bool, x: u64) u64 {
    if (x >= Type(wide).n) return 0;
    return x * (1 << 59);
}
pub fn f(r: *std.Io.Reader) !u64 {
    const x: u64 = try r.takeInt(u64, .little);
    return g(true, x);
}
