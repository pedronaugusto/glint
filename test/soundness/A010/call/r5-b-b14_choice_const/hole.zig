// review 5: b/b14_choice_const.zig
const std = @import("std");
const builtin = @import("builtin");
const Small = struct {
    pub const n = 4;
};
const Large = struct {
    pub const n = 64;
};
const T = if (builtin.mode == .debug) Small else Large;
pub fn f(r: *std.Io.Reader) !u64 {
    const x: u64 = try r.takeInt(u64, .little);
    if (x >= T.n) return 0;
    return x * (1 << 59);
}
