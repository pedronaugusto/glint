// consolidate: a decl literal whose place is std's Duration in one build and the program's own type in
// another: read per build, where it is std's it is the door, never a literal that names none
const std = @import("std");
const builtin = @import("builtin");
const Ticks = struct {
    n: i64,
    pub fn fromMilliseconds(ms: i64) Ticks {
        return .{ .n = ms };
    }
};
const Span = if (builtin.os.tag == .windows) Ticks else std.Io.Duration;
pub fn f(ms: i64) Span {
    var d: Span = undefined;
    d = .fromMilliseconds(ms);
    return d;
}
