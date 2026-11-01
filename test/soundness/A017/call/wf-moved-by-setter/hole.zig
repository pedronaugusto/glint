// warp-fast: two functions move the state, each under a condition on it, through one setter.
const State = enum { idle, running, done };
pub const Job = struct {
    state: State = .idle,
    fn set(j: *Job, s: State) void {
        j.state = s;
    }
    pub fn start(j: *Job) void {
        if (j.state == .idle) j.set(.running);
    }
    pub fn finish(j: *Job) void {
        if (j.state == .running) j.set(.done);
    }
    pub fn report(j: *const Job) u8 {
        return switch (j.state) {
            .idle => 0,
            .running => 1,
            .done => 2,
        };
    }
};
