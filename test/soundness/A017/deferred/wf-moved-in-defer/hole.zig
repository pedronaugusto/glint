// warp-fast: the state moved by a defer in one function and by `=` in another, under switches.
const State = enum { idle, running, done };
pub const Job = struct {
    state: State = .idle,
    pub fn start(j: *Job) void {
        if (j.state == .idle) j.state = .running;
    }
    pub fn run(j: *Job) void {
        switch (j.state) {
            .running => {
                defer j.state = .done;
            },
            else => {},
        }
    }
    pub fn report(j: *const Job) u8 {
        return switch (j.state) {
            .idle => 0,
            .running => 1,
            .done => 2,
        };
    }
};
