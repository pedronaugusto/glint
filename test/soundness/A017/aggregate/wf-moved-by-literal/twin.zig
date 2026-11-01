// warp-fast: a struct literal gives the kind where the value is built.
const State = enum { idle, running, done };
pub const Job = struct {
    state: State = .idle,
    n: u32 = 0,
    pub fn make(done: bool) Job {
        return .{ .state = if (done) .done else .idle, .n = 0 };
    }
    pub fn report(j: *const Job) u8 {
        return switch (j.state) {
            .idle => 0,
            .running => 1,
            .done => 2,
        };
    }
};
