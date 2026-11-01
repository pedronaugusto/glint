// warp-fast: a kind set where the value is built and only read after: data, no machine.
const State = enum { idle, running, done };
pub const Job = struct {
    state: State,
    pub fn idle() Job {
        return .{ .state = .idle };
    }
    pub fn done() Job {
        var j: Job = .{ .state = .idle };
        j.state = .done;
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
