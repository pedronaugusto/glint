// review 5: b/b05c_errunion_safe.zig
const std = @import("std");
const R = error{Big}!u64;
fn check(n: u64) R {
    if (n >= 10) return error.Big;
    return n;
}
pub fn f(r: *std.Io.Reader) !u64 {
    const n: u64 = try r.takeInt(u64, .little);
    _ = try check(n);
    return n * 1000;
}
