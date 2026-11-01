// warp-fast: the state converted from a code under a switch on it, in two functions.
const State = enum { idle, running, done };
pub const Job = struct {
    state: State = .idle,
    pub fn start(j: *Job, code: u2) void {
        switch (j.state) {
            .idle => j.state = @enumFromInt(code),
            else => {},
        }
    }
    pub fn finish(j: *Job) void {
        if (j.state == .running) j.state = @as(State, .done);
    }
    pub fn report(j: *const Job) u8 {
        return switch (j.state) {
            .idle => 0,
            .running => 1,
            .done => 2,
        };
    }
};
