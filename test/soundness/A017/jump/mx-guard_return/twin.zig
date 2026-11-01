// matrix: each step guarded by a return on the machine's state before it
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
    pub fn start(j: *Job) !void {
        if (j.life.current() != .idle) return;
        _ = try j.life.step(.start);
    }
    pub fn finish(j: *Job) !void {
        if (j.life.current() != .running) return;
        _ = try j.life.step(.finish);
    }
    pub fn label(j: *const Job) []const u8 {
        return switch (j.life.current()) {
            .idle => "idle",
            .running => "running",
            .done => "done",
        };
    }
};
