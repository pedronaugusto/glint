// review 6: b/k06_alias_errunion_param.zig
const std = @import("std");
// The error union named through a function's comptime parameter: fn check(comptime R: type, ...) R.
fn check(comptime R: type, n: u64) R {
    if (n >= 10) return error.Big;
    return n;
}
pub fn f(r: *std.Io.Reader) !u64 {
    const n: u64 = try r.takeInt(u64, .little);
    _ = check(error{Big}!u64, n) catch 0;
    return n * 1000;
}
