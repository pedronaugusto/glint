// warp-fast: each job a loop captures by pointer is given its kind once, not on its own value.
const State = enum { idle, running, done };
pub const Job = struct {
    state: State = .idle,
    pub fn report(j: *const Job) u8 {
        return switch (j.state) {
            .idle => 0,
            .running => 1,
            .done => 2,
        };
    }
};
pub fn reset(jobs: []Job) void {
    for (jobs) |*j| j.state = .idle;
}
