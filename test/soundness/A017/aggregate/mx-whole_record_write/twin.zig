// matrix: the machine carried in a whole-record literal after its step, under a switch on its state
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
    pub fn reset(j: *Job) void {
        j.* = .{};
    }
    pub fn step(j: *Job) !void {
        var life = j.life;
        switch (life.current()) {
            .idle => _ = try life.step(.start),
            .running => _ = try life.step(.finish),
            .done => return,
        }
        j.* = .{ .life = life, .ticks = j.ticks +% 1 };
    }
};
