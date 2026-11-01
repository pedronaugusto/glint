// matrix: the next event chosen by a switch on the state and stepped by a defer
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
    pub fn step(j: *Job) void {
        var next: ?Event = null;
        defer if (next) |on| {
            _ = j.life.step(on) catch {};
        };
        switch (j.life.current()) {
            .idle => next = .start,
            .running => next = .finish,
            .done => {},
        }
    }
};
