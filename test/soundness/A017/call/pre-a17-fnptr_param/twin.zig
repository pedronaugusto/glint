// The writers reached through a function pointer the caller hands in, called plainly.
const Phase = enum { idle, running, done };
pub const Job = struct {
    phase: Phase = .idle,
    pub fn start(j: *Job) void {
        j.phase = .running;
    }
    pub fn stop(j: *Job) void {
        j.phase = .done;
    }
    pub fn step(j: *Job, act: *const fn (*Job) void) void {
        act(j);
    }
    pub fn label(j: *const Job) u8 {
        return switch (j.phase) {
            .idle => 0,
            .running => 1,
            .done => 2,
        };
    }
};
