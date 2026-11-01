// warp-fast: a setter called once where the value is built.
const State = enum { idle, running, done };
pub const Job = struct {
    state: State = .idle,
    fn set(j: *Job, s: State) void {
        j.state = s;
    }
    pub fn make(done: bool) Job {
        var j: Job = .{};
        j.set(if (done) .done else .idle);
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
