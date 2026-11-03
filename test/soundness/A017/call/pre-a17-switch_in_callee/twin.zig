// Another value handed to a function that switches on it; the state written plainly.
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
    pub fn step(j: *Job, from: Phase) void {
        j.phase = next(from);
    }
    pub fn reset(j: *Job) void {
        j.phase = .idle;
    }
};
