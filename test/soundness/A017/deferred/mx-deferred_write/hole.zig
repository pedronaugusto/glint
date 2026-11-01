// matrix: the next state chosen by a switch on it and written by a defer
const Phase = enum { idle, running, done };
pub const Job = struct {
    phase: Phase = .idle,
    pub fn reset(j: *Job) void {
        j.phase = .idle;
    }
    pub fn step(j: *Job) void {
        var next = j.phase;
        defer j.phase = next;
        switch (j.phase) {
            .idle => next = .running,
            .running => next = .done,
            .done => {},
        }
    }
};
