// warp-fast: the state moved by destructures in two functions, each under a condition on it.
const State = enum { idle, running, done };
pub const Job = struct {
    state: State = .idle,
    n: u32 = 0,
    pub fn start(j: *Job) void {
        if (j.state == .idle) j.state, j.n = .{ .running, 1 };
    }
    pub fn finish(j: *Job) void {
        if (j.state == .running) j.state, j.n = .{ .done, 2 };
    }
    pub fn report(j: *const Job) u8 {
        return switch (j.state) {
            .idle => 0,
            .running => 1,
            .done => 2,
        };
    }
};
