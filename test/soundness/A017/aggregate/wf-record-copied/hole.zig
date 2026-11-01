// warp-fast: a record literal stored over one under a switch on its state: a state chosen there.
const State = enum { idle, running, done };
pub const Job = struct {
    state: State = .idle,
    id: u32 = 0,
    pub fn start(j: *Job) void {
        j.state = .running;
    }
    pub fn finish(j: *Job) void {
        j.state = .done;
    }
};
pub fn keep(kept: *Job, seen: Job) void {
    switch (seen.state) {
        .done => kept.* = .{ .state = .idle, .id = seen.id },
        else => {},
    }
}
