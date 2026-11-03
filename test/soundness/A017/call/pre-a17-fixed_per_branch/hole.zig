// One setter whose writes are each fixed, the caller choosing which by an argument: start and stop move the state.
const Phase = enum { idle, running, done };
pub const Job = struct {
    phase: Phase = .idle,
    fn go(j: *Job, done: bool) void {
        if (done) {
            j.phase = .done;
        } else {
            j.phase = .running;
        }
    }
    pub fn start(j: *Job) void {
        switch (j.phase) {
            .idle => j.go(false),
            else => {},
        }
    }
    pub fn stop(j: *Job) void {
        switch (j.phase) {
            .running => j.go(true),
            else => {},
        }
    }
};
