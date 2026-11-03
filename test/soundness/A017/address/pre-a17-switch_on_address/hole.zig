// The state switched on through a pointer to it, moved under that switch.
const Phase = enum { idle, running, done };
pub const Job = struct {
    phase: Phase = .idle,
    pub fn step(j: *Job) void {
        const p = &j.phase;
        switch (p.*) {
            .idle => j.phase = .running,
            .running => j.phase = .done,
            .done => {},
        }
    }
    pub fn reset(j: *Job) void {
        j.phase = .idle;
    }
};
