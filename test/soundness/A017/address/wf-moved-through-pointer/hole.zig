// warp-fast: the state moved through a pointer to it, in two functions, under conditions on it.
const State = enum { idle, running, done };
pub const Job = struct {
    state: State = .idle,
    pub fn start(j: *Job) void {
        const s = &j.state;
        if (s.* == .idle) s.* = .running;
    }
    pub fn finish(j: *Job) void {
        const s = &j.state;
        if (s.* == .running) s.* = .done;
    }
    pub fn report(j: *const Job) u8 {
        return switch (j.state) {
            .idle => 0,
            .running => 1,
            .done => 2,
        };
    }
};
