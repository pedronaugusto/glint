// warp-fast: the state moved by atomic stores in two functions, each under a condition on it.
const State = enum { idle, running, done };
pub const Job = struct {
    state: State = .idle,
    pub fn start(j: *Job) void {
        if (j.state == .idle) @atomicStore(State, &j.state, .running, .release);
    }
    pub fn finish(j: *Job) void {
        if (j.state == .running) @atomicStore(State, &j.state, .done, .release);
    }
    pub fn report(j: *const Job) u8 {
        return switch (j.state) {
            .idle => 0,
            .running => 1,
            .done => 2,
        };
    }
};
