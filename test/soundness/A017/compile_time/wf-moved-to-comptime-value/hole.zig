// warp-fast: a function given the next state at comptime moves it under a condition on it,
// called from two functions.
const State = enum { idle, running, done };
pub const Job = struct {
    state: State = .idle,
    fn move(j: *Job, comptime from: State, comptime to: State) void {
        if (j.state == from) j.state = to;
    }
    pub fn start(j: *Job) void {
        j.move(.idle, .running);
    }
    pub fn finish(j: *Job) void {
        j.move(.running, .done);
    }
    pub fn cancel(j: *Job) void {
        j.state = .done;
    }
    pub fn report(j: *const Job) u8 {
        return switch (j.state) {
            .idle => 0,
            .running => 1,
            .done => 2,
        };
    }
};
