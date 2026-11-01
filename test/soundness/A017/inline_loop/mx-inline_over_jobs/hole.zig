// matrix: the state switched on and moved through an inline loop's capture of each job
const Phase = enum { idle, running, done };
pub const Job = struct {
    phase: Phase = .idle,
    pub fn reset(j: *Job) void {
        j.phase = .idle;
    }
};
pub fn stepBoth(a: *Job, b: *Job) void {
    inline for (.{ a, b }) |j| switch (j.phase) {
        .idle => j.phase = .running,
        .running => j.phase = .done,
        .done => {},
    };
}
