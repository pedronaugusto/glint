// consolidate: a method that makes a type, called on a receiver that is a value in one build and a
// pointer to it in another: either way the value is its first parameter, so `Of(Duration, i64)` is
// std's Duration and `.fromMilliseconds` its door (read with the receiver dropped, it was i64)
const std = @import("std");
const builtin = @import("builtin");
const Maker = struct {
    pub fn Of(_: Maker, comptime A: type, comptime B: type) type {
        _ = B;
        return A;
    }
};
const maker: Maker = .{};
const pick = if (builtin.os.tag == .windows) maker else &maker;
pub fn f(ms: i64) pick.Of(std.Io.Duration, i64) {
    var d: pick.Of(std.Io.Duration, i64) = undefined;
    d = .fromMilliseconds(ms);
    return d;
}
