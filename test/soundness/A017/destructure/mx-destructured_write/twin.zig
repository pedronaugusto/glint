// matrix: the machine stepped beside a destructure of the job's other data, under a switch on its state
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
    ticks: u32 = 0,
    seen: u32 = 0,
    pub fn reset(j: *Job) !void {
        _ = try j.life.step(.reset);
        j.ticks, j.seen = .{ 0, 0 };
    }
    pub fn step(j: *Job) !void {
        switch (j.life.current()) {
            .idle => {
                _ = try j.life.step(.start);
                j.ticks, j.seen = .{ j.ticks +% 1, j.seen };
            },
            .running => {
                _ = try j.life.step(.finish);
                j.ticks, j.seen = .{ j.ticks +% 1, j.seen +% 1 };
            },
            .done => {},
        }
    }
};
