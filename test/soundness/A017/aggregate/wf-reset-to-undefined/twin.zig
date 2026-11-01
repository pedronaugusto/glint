// warp-fast: a record's deinit stores `undefined` over it: no state, so no writer of one.
const State = enum { idle, running };
pub const Job = struct {
    state: State = .idle,
    pub fn start(j: *Job) void {
        j.state = .running;
    }
    pub fn deinit(j: *Job) void {
        j.* = undefined;
    }
};
pub fn finish(j: *Job) void {
    switch (j.state) {
        .running => j.deinit(),
        .idle => {},
    }
}
