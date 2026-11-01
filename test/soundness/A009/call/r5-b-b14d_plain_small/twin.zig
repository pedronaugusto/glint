// review 5: b/b14d_plain_small.zig
const std = @import("std");
const Small = struct {
    pub const n = 4;
};
pub fn f(r: *std.Io.Reader) !u64 {
    const x: u64 = try r.takeInt(u64, .little);
    if (x >= Small.n) return 0;
    return x * (1 << 59);
}
