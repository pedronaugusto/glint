// warp-fast: a kind converted from a code where the value is built.
const State = enum { idle, running, done };
pub const Job = struct {
    state: State = .idle,
    pub fn make(code: u2) Job {
        var j: Job = .{};
        j.state = @enumFromInt(code);
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
