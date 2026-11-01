// warp-fast: a record's reset stores a literal over it, called under a switch on its state.
const State = enum { idle, running };
pub const Job = struct {
    state: State = .idle,
    pub fn start(j: *Job) void {
        j.state = .running;
    }
    pub fn reset(j: *Job) void {
        j.* = .{ .state = .idle };
    }
};
pub fn finish(j: *Job) void {
    switch (j.state) {
        .running => j.reset(),
        .idle => {},
    }
}
