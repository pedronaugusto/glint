// warp-fast: the state advanced by arithmetic on its own value, in two functions.
const State = enum { idle, running, done };
pub const Job = struct {
    state: State = .idle,
    pub fn step(j: *Job) void {
        j.state = @enumFromInt(@intFromEnum(j.state) + 1);
    }
    pub fn skip(j: *Job) void {
        j.state = @enumFromInt(@intFromEnum(j.state) + 2);
    }
    pub fn report(j: *const Job) u8 {
        return switch (j.state) {
            .idle => 0,
            .running => 1,
            .done => 2,
        };
    }
};
