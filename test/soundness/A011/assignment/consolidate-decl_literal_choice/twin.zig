// consolidate: a decl literal whose place is the program's own type in every build, optional in one:
// each build names the one declaration, no door
const builtin = @import("builtin");
const Ticks = struct {
    n: i64,
    pub fn fromMilliseconds(ms: i64) Ticks {
        return .{ .n = ms };
    }
};
const Span = if (builtin.os.tag == .windows) Ticks else ?Ticks;
pub fn f(ms: i64) Span {
    var d: Span = undefined;
    d = .fromMilliseconds(ms);
    return d;
}
