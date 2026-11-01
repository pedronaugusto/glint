// warp-fast: a state written by `=` in two functions, each under a switch on it.
const State = enum { idle, running, done };
pub const Job = struct {
    state: State = .idle,
    pub fn start(j: *Job) void {
        switch (j.state) {
            .idle => j.state = .running,
            else => {},
        }
    }
    pub fn finish(j: *Job) void {
        if (j.state == .running) j.state = .done;
    }
    pub fn report(j: *const Job) u8 {
        return switch (j.state) {
            .idle => 0,
            .running => 1,
            .done => 2,
        };
    }
};
