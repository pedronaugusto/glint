// review 6: b/k08_anyerror_alias.zig
const std = @import("std");
const E = anyerror;
// An error union whose payload is named and whose error set is named: E!u64 written in place.
fn check(n: u64) E!u64 {
    if (n >= 10) return error.Big;
    return n;
}
pub fn f(r: *std.Io.Reader) !u64 {
    const n: u64 = try r.takeInt(u64, .little);
    _ = check(n) catch 0;
    return n * 1000;
}
