// warp-fast: the state written through @field in two functions, each under a condition on it.
const State = enum { idle, running, done };
pub const Job = struct {
    state: State = .idle,
    pub fn start(j: *Job) void {
        if (j.state == .idle) @field(j, "state") = .running;
    }
    pub fn finish(j: *Job) void {
        if (j.state == .running) @field(j, "state") = .done;
    }
    pub fn report(j: *const Job) u8 {
        return switch (j.state) {
            .idle => 0,
            .running => 1,
            .done => 2,
        };
    }
};
