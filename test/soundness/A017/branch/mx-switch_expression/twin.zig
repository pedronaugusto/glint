// matrix: the machine stepped by the event a switch expression on its state chooses
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
    pub fn step(j: *Job) !void {
        const on: Event = switch (j.life.current()) {
            .idle => .start,
            .running => .finish,
            .done => return,
        };
        _ = try j.life.step(on);
    }
};
