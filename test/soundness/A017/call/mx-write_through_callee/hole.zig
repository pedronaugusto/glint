// matrix: the state written by a callee given its address, under a switch on it
const Phase = enum { idle, running, done };
fn set(p: *Phase, to: Phase) void {
    p.* = to;
}
pub const Job = struct {
    phase: Phase = .idle,
    pub fn reset(j: *Job) void {
        set(&j.phase, .idle);
    }
    pub fn step(j: *Job) void {
        switch (j.phase) {
            .idle => set(&j.phase, .running),
            .running => set(&j.phase, .done),
            .done => {},
        }
    }
};
