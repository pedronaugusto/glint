// review 6: b/k05b_optional_used.zig
const std = @import("std");
fn check(n: u64) ?u64 {
    if (n >= 10) return null;
    return n;
}
// Twin: the bound is used only where check gave a value.
pub fn f(r: *std.Io.Reader) !u64 {
    const n: u64 = try r.takeInt(u64, .little);
    const m = check(n) orelse return 0;
    return m * 1000;
}
