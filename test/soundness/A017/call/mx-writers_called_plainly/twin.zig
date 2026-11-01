// matrix: the machine's steppers called as free functions from the prongs of a switch on it
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
};
fn start(j: *Job) !void {
    _ = try j.life.step(.start);
}
fn finish(j: *Job) !void {
    _ = try j.life.step(.finish);
}
pub fn step(j: *Job) !void {
    switch (j.life.current()) {
        .idle => try start(j),
        .running => try finish(j),
        .done => {},
    }
}
