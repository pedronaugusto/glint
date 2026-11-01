// review 5: b/h05_recursion.zig
const std = @import("std");
fn g(n: u64, d: u8) u64 {
    if (d == 0) return n;
    if (n > 10) unreachable;
    return g(n, d - 1);
}
pub fn f(r: *std.Io.Reader) !u64 {
    const n: u64 = try r.takeInt(u64, .little);
    _ = g(n, 0);
    return n * 1000;
}
