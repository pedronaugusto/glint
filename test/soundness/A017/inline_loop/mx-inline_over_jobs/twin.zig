// matrix: each job's machine stepped through an inline loop's capture of it
const aegis = @import("aegis");
const Phase = enum { idle, running, done };
const Event = enum { start, finish, reset };
const Life = aegis.state.Machine(Phase, Event, .{ .initial = .idle, .edges = &.{
    .{ .from = .idle, .on = .start, .to = .running },
    .{ .from = .running, .on = .finish, .to = .done },
    .{ .from = .done, .on = .reset, .to = .idle },
} });
pub const Job = struct {
    life: Life.Runtime(void) = .init({}),
    pub fn reset(j: *Job) !void {
        _ = try j.life.step(.reset);
    }
};
pub fn stepBoth(a: *Job, b: *Job) !void {
    inline for (.{ a, b }) |j| switch (j.life.current()) {
        .idle => _ = try j.life.step(.start),
        .running => _ = try j.life.step(.finish),
        .done => {},
    };
}
