// The state handed to a function that switches on it and gives the next one.
const Phase = enum { idle, running, done };
fn next(p: Phase) Phase {
    return switch (p) {
        .idle => .running,
        .running => .done,
        .done => .done,
    };
}
pub const Job = struct {
    phase: Phase = .idle,
    pub fn step(j: *Job) void {
        const p = j.phase;
        j.phase = next(p);
    }
    pub fn reset(j: *Job) void {
        j.phase = .idle;
    }
};
