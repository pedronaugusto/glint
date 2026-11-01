// matrix: the state moved to what a switch expression on it chooses
const Phase = enum { idle, running, done };
pub const Job = struct {
    phase: Phase = .idle,
    pub fn reset(j: *Job) void {
        j.phase = .idle;
    }
    pub fn step(j: *Job) void {
        j.phase = switch (j.phase) {
            .idle => .running,
            .running => .done,
            .done => .done,
        };
    }
};
