// review 5: b/b14c_plain_large.zig
const std = @import("std");
const Large = struct {
    pub const n = 64;
};
pub fn f(r: *std.Io.Reader) !u64 {
    const x: u64 = try r.takeInt(u64, .little);
    if (x >= Large.n) return 0;
    return x * (1 << 59);
}
