// consolidate: a struct literal whose type is std's Duration in one build and the program's own type
// in another: its field label is std's raw nanoseconds where it is std's, never a label that names none
const std = @import("std");
const builtin = @import("builtin");
const Ticks = struct { nanoseconds: i96 };
const Span = if (builtin.os.tag == .windows) Ticks else std.Io.Duration;
pub fn f(ms: i64) Span {
    return .{ .nanoseconds = @as(i96, ms) * 1_000_000 };
}
