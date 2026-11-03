// The next state chosen by a switch on the state into a local, then stored: moved on its own value.
const Phase = enum { idle, running, done };
pub const Job = struct {
    phase: Phase = .idle,
    pub fn reset(j: *Job) void {
        j.phase = .idle;
    }
    pub fn step(j: *Job) void {
        const next: Phase = switch (j.phase) {
            .idle => .running,
            .running => .done,
            .done => .done,
        };
        j.phase = next;
    }
};
