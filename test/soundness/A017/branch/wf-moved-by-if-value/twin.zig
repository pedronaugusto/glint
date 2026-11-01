// warp-fast: an if expression on a flag gives the kind where the value is built.
const State = enum { idle, running, done };
pub const Job = struct {
    state: State = .idle,
    pub fn make(done: bool) Job {
        var j: Job = .{};
        j.state = if (done) .done else .idle;
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
