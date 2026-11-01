// warp-fast: an optional kind given where the value is built.
const State = enum { idle, running, done };
pub const Job = struct {
    state: ?State = null,
    pub fn make(kind: ?State) Job {
        var j: Job = .{};
        j.state = kind orelse .idle;
        return j;
    }
    pub fn report(j: *const Job) u8 {
        return switch (j.state orelse .idle) {
            .idle => 0,
            .running => 1,
            .done => 2,
        };
    }
};
