// warp-fast: arithmetic chooses the kind from a count where the value is built.
const State = enum { idle, running, done };
pub const Job = struct {
    state: State = .idle,
    pub fn make(n: u2) Job {
        var j: Job = .{};
        j.state = @enumFromInt(n % 3);
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
