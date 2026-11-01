// review 5: b/h03_summary_partial.zig
const std = @import("std");
fn check(n: u64) !u64 {
    if (n >= 10) return error.Big;
    return n;
}
pub fn f(r: *std.Io.Reader) !u64 {
    const n: u64 = try r.takeInt(u64, .little);
    _ = check(n) catch 0;
    return n * 1000;
}
