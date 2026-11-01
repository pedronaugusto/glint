// review 6: b/k07_errunion_typeof.zig
const std = @import("std");
const proto: error{Big}!u64 = 0;
// The result type spelled @TypeOf(...).
fn check(n: u64) @TypeOf(proto) {
    if (n >= 10) return error.Big;
    return n;
}
pub fn f(r: *std.Io.Reader) !u64 {
    const n: u64 = try r.takeInt(u64, .little);
    _ = check(n) catch 0;
    return n * 1000;
}
