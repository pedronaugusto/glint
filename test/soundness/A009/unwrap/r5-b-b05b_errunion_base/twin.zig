// review 5: b/b05b_errunion_base.zig
const std = @import("std");
fn check(n: u64) error{Big}!u64 {
    if (n >= 10) return error.Big;
    return n;
}
pub fn f(r: *std.Io.Reader) !u64 {
    const n: u64 = try r.takeInt(u64, .little);
    _ = check(n) catch 0;
    return n * 1000;
}
