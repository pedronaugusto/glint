// matrix: an optional machine captured by `if` and switched on through the capture
const aegis = @import("aegis");
const Phase = enum { idle, running, done };
const Event = enum { start, finish, reset };
const Life = aegis.state.Machine(Phase, Event, .{ .initial = .idle, .edges = &.{
    .{ .from = .idle, .on = .start, .to = .running },
    .{ .from = .running, .on = .finish, .to = .done },
    .{ .from = .done, .on = .reset, .to = .idle },
} });
pub const Job = struct {
    life: ?Life.Runtime(void) = null,
    pub fn reset(j: *Job) void {
        j.life = .init({});
    }
    pub fn step(j: *Job) !void {
        if (j.life) |*life| switch (life.current()) {
            .idle => _ = try life.step(.start),
            .running => _ = try life.step(.finish),
            .done => {},
        };
    }
};
