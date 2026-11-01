// warp-fast: an optional state moved in two functions, each under a condition on it.
const State = enum { idle, running, done };
pub const Job = struct {
    state: ?State = null,
    pub fn start(j: *Job) void {
        if (j.state == null) j.state = .running;
    }
    pub fn finish(j: *Job) void {
        if (j.state == .running) j.state = .done;
    }
    pub fn report(j: *const Job) u8 {
        return switch (j.state orelse .idle) {
            .idle => 0,
            .running => 1,
            .done => 2,
        };
    }
};
