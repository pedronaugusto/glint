// matrix: the state moved on its own value through a transition table indexed by it
const Phase = enum { idle, running, done };
const after = [_]Phase{ .running, .done, .idle };
pub const Job = struct {
    phase: Phase = .idle,
    pub fn reset(j: *Job) void {
        j.phase = .idle;
    }
    pub fn advance(j: *Job) void {
        j.phase = after[@backingInt(j.phase)];
    }
    pub fn label(j: *const Job) []const u8 {
        return switch (j.phase) {
            .idle => "idle",
            .running => "running",
            .done => "done",
        };
    }
};
