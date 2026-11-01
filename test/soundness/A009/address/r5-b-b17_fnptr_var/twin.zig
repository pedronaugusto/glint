// review 5: b/b17_fnptr_var.zig
const std = @import("std");
fn g(n: u64) u64 {
    if (n > 10) unreachable;
    return n;
}
fn k(n: u64) u64 {
    return n;
}
pub fn f(r: *std.Io.Reader, c: bool) !u64 {
    var h: *const fn (u64) u64 = &g;
    if (c) h = &k;
    const n: u64 = try r.takeInt(u64, .little);
    _ = h(n);
    return n * 1000;
}
