// review 5: b/b05d_typefn_errunion.zig
const std = @import("std");
fn Result(comptime T: type) type {
    return error{Big}!T;
}
fn check(n: u64) Result(u64) {
    if (n >= 10) return error.Big;
    return n;
}
pub fn f(r: *std.Io.Reader) !u64 {
    const n: u64 = try r.takeInt(u64, .little);
    if (check(n)) |_| {} else |_| {}
    return n * 1000;
}
