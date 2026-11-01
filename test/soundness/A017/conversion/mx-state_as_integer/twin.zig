// matrix: the machine stepped by an event converted from an integer the job holds
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
    pending: u8 = 0,
    pub fn reset(j: *Job) !void {
        _ = try j.life.step(.reset);
    }
    pub fn step(j: *Job) !void {
        switch (j.life.current()) {
            .idle, .running => _ = try j.life.step(@as(Event, @fromBackingInt(@intCast(j.pending % 2)))),
            .done => {},
        }
    }
};
