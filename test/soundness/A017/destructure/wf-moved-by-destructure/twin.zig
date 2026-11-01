// warp-fast: a destructure sets the kind once where the value is built.
const State = enum { idle, running, done };
pub const Job = struct {
    state: State = .idle,
    n: u32 = 0,
    pub fn make(done: bool) Job {
        var j: Job = .{};
        j.state, j.n = .{ if (done) .done else .idle, 0 };
        return j;
    }
    pub fn report(j: *const Job) u8 {
        return switch (j.state) {
            .idle => 0,
            .running => 1,
            .done => 2,
        };
    }
};
