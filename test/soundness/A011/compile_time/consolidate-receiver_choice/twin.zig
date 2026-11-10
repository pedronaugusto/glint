// consolidate: the same receiver, a value in one build and a pointer in another, making the program's
// own type: `Of(Ticks, Duration)` is Ticks, no door (read with the receiver dropped, it was std's)
const std = @import("std");
const builtin = @import("builtin");
const Ticks = struct {
    n: i64,
    pub fn fromMilliseconds(ms: i64) Ticks {
        return .{ .n = ms };
    }
};
const Maker = struct {
    pub fn Of(_: Maker, comptime A: type, comptime B: type) type {
        _ = B;
        return A;
    }
};
const maker: Maker = .{};
const pick = if (builtin.os.tag == .windows) maker else &maker;
pub fn f(ms: i64) pick.Of(Ticks, std.Io.Duration) {
    var d: pick.Of(Ticks, std.Io.Duration) = undefined;
    d = .fromMilliseconds(ms);
    return d;
}
