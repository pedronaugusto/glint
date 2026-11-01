// matrix: an optional state captured by `if` and switched on through the capture
const Phase = enum { idle, running, done };
pub const Job = struct {
    phase: ?Phase = null,
    pub fn reset(j: *Job) void {
        j.phase = .idle;
    }
    pub fn step(j: *Job) void {
        if (j.phase) |now| switch (now) {
            .idle => j.phase = .running,
            .running => j.phase = .done,
            .done => {},
        };
    }
};
