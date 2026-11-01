// review 5: b/b14f_typefn_param.zig
const std = @import("std");
fn Sized(comptime k: comptime_int) type {
    return struct {
        pub const n = k;
    };
}
pub fn g(comptime k: comptime_int, x: u64) u64 {
    const T = Sized(k);
    if (x >= T.n) return 0;
    return x * (1 << 59);
}
pub fn f(r: *std.Io.Reader) !u64 {
    const x: u64 = try r.takeInt(u64, .little);
    return g(4, x) +% g(64, x);
}
