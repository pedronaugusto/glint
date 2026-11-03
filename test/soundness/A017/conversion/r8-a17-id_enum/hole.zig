// warp-fast: a non-exhaustive enum that names its tags is a state: moved on its own value in two
// functions and switched on.
const State = enum(u8) { idle, running, done, _ };
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
            else => 2,
        };
    }
};
