// matrix: the machine stepped by an event a table indexed by its state names
const aegis = @import("aegis");
const Phase = enum { idle, running, done };
const Event = enum { start, finish, reset };
const Life = aegis.state.Machine(Phase, Event, .{ .initial = .idle, .edges = &.{
    .{ .from = .idle, .on = .start, .to = .running },
    .{ .from = .running, .on = .finish, .to = .done },
    .{ .from = .done, .on = .reset, .to = .idle },
} });
const event = [_]Event{ .start, .finish, .reset };
pub const Job = struct {
    life: Life.Runtime(void) = .init({}),
    pub fn reset(j: *Job) void {
        j.life = .init({});
    }
    pub fn advance(j: *Job) !void {
        _ = try j.life.step(event[@backingInt(j.life.current())]);
    }
    pub fn label(j: *const Job) []const u8 {
        return switch (j.life.current()) {
            .idle => "idle",
            .running => "running",
            .done => "done",
        };
    }
};
