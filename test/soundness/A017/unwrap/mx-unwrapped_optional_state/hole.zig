// matrix: an optional state unwrapped by `.?` in the switch that moves it
const Phase = enum { idle, running, done };
pub const Job = struct {
    phase: ?Phase = .idle,
    pub fn reset(j: *Job) void {
        j.phase = .idle;
    }
    pub fn step(j: *Job) void {
        switch (j.phase.?) {
            .idle => j.phase = .running,
            .running => j.phase = .done,
            .done => {},
        }
    }
};
