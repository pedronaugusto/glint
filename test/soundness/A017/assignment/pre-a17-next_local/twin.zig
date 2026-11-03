// The next state chosen by a switch on another field into a local, then stored.
const Phase = enum { idle, running, done };
pub const Job = struct {
    phase: Phase = .idle,
    mode: Phase = .idle,
    pub fn reset(j: *Job) void {
        j.phase = .idle;
    }
    pub fn step(j: *Job) void {
        const next: Phase = switch (j.mode) {
            .idle => .running,
            .running => .done,
            .done => .done,
        };
        j.phase = next;
    }
    pub fn label(j: *const Job) u8 {
        return switch (j.phase) {
            .idle => 0,
            .running => 1,
            .done => 2,
        };
    }
};
