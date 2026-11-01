// warp-fast: each job a loop captures by pointer is moved under a switch on its state, in two
// functions.
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
pub fn startAll(jobs: []Job) void {
    for (jobs) |*j| switch (j.state) {
        .idle => j.state = .running,
        else => {},
    };
}
pub fn finishAll(jobs: []Job) void {
    for (jobs) |*j| if (j.state == .running) {
        j.state = .done;
    };
}
