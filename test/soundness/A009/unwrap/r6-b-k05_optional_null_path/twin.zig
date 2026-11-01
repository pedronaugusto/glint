// review 6: b/k05_optional_null_path.zig
const std = @import("std");
// check returns null when n is large: the caller's orelse path holds no bound on n.
fn check(n: u64) ?u64 {
    if (n >= 10) return null;
    return n;
}
pub fn f(r: *std.Io.Reader) !u64 {
    const n: u64 = try r.takeInt(u64, .little);
    _ = check(n) orelse 0;
    return n * 1000;
}
