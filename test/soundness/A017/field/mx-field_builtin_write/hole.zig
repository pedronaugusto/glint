// matrix: one of the state's two writers writes it by `@field`
const Phase = enum { idle, running, done };
pub const Job = struct {
    phase: Phase = .idle,
    pub fn reset(j: *Job) void {
        @field(j, "phase") = .idle;
    }
    pub fn step(j: *Job) void {
        switch (j.phase) {
            .idle => j.phase = .running,
            .running => j.phase = .done,
            .done => {},
        }
    }
};
