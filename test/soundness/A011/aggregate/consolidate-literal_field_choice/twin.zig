// consolidate: a struct literal whose type is the program's own in every build, optional in one: each
// build's label names the one field, no door
const builtin = @import("builtin");
const Ticks = struct { nanoseconds: i96 };
const Span = if (builtin.os.tag == .windows) Ticks else ?Ticks;
pub fn f(ms: i64) Span {
    return .{ .nanoseconds = @as(i96, ms) * 1_000_000 };
}
