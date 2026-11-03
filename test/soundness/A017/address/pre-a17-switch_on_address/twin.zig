// A pointer to another field switched on; the state written plainly.
const Phase = enum { idle, running, done };
pub const Job = struct {
    phase: Phase = .idle,
    mode: Phase = .idle,
    pub fn step(j: *Job) void {
        const p = &j.mode;
        switch (p.*) {
            .idle => j.phase = .running,
            .running => j.phase = .done,
            .done => {},
        }
    }
    pub fn reset(j: *Job) void {
        j.phase = .idle;
    }
    pub fn label(j: *const Job) u8 {
        return switch (j.phase) {
            .idle => 0,
            .running => 1,
            .done => 2,
        };
    }
};
