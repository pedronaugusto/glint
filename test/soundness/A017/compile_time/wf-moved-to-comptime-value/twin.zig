// warp-fast: a comptime kind given where the value is built.
const State = enum { idle, running, done };
pub const Job = struct {
    state: State = .idle,
    pub fn make(comptime kind: State) Job {
        var j: Job = .{};
        j.state = kind;
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
