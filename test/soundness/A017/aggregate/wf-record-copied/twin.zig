// warp-fast: a whole record copied under a switch on its state: the state it carries was chosen where it was made.
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
    pub fn report(j: *const Job) u8 {
        return switch (j.state) {
            .idle => 0,
            .running => 1,
            .done => 2,
        };
    }
};
pub fn keep(kept: *Job, seen: Job) void {
    switch (seen.state) {
        .done => kept.* = seen,
        else => {},
    }
}
