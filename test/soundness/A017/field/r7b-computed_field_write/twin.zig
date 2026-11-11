// twin: the second function writes only the counter, by its name: one writer of the state
const Phase = enum { idle, running, done };
pub const Job = struct {
    phase: Phase = .idle,
    count: u32 = 0,
    pub fn reset(j: *Job) void {
        j.count = 0;
    }
    pub fn step(j: *Job) void {
        switch (j.phase) {
            .idle => j.phase = .running,
            .running => j.phase = .done,
            .done => {},
        }
    }
};
