// review 5: b/b17b_fnptr_direct_base.zig
const std = @import("std");
fn k(n: u64) u64 {
    return n;
}
pub fn f(r: *std.Io.Reader) !u64 {
    const n: u64 = try r.takeInt(u64, .little);
    _ = k(n);
    return n * 1000;
}
