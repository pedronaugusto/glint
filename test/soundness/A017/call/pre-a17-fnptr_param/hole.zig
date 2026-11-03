// The writers reached through a function pointer the caller hands in, called under a switch on the state.
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
        switch (j.phase) {
            .idle, .running => act(j),
            .done => {},
        }
    }
};
