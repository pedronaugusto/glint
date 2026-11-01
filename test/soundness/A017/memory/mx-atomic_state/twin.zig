// matrix: the machine stepped beside a counter the job loads and stores by atomics
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
    steps: u32 = 0,
    pub fn reset(j: *Job) !void {
        _ = try j.life.step(.reset);
        @atomicStore(u32, &j.steps, 0, .release);
    }
    pub fn step(j: *Job) !void {
        switch (j.life.current()) {
            .idle => _ = try j.life.step(.start),
            .running => _ = try j.life.step(.finish),
            .done => return,
        }
        @atomicStore(u32, &j.steps, @atomicLoad(u32, &j.steps, .acquire) +% 1, .release);
    }
};
