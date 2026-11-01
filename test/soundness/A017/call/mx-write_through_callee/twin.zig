// matrix: the machine stepped by a callee given its address, under a switch on its state
const aegis = @import("aegis");
const Phase = enum { idle, running, done };
const Event = enum { start, finish, reset };
const Life = aegis.state.Machine(Phase, Event, .{ .initial = .idle, .edges = &.{
    .{ .from = .idle, .on = .start, .to = .running },
    .{ .from = .running, .on = .finish, .to = .done },
    .{ .from = .done, .on = .reset, .to = .idle },
} });
fn fire(life: *Life.Runtime(void), on: Event) !void {
    _ = try life.step(on);
}
pub const Job = struct {
    life: Life.Runtime(void) = .init({}),
    pub fn reset(j: *Job) !void {
        try fire(&j.life, .reset);
    }
    pub fn step(j: *Job) !void {
        switch (j.life.current()) {
            .idle => try fire(&j.life, .start),
            .running => try fire(&j.life, .finish),
            .done => {},
        }
    }
};
