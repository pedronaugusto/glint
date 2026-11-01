// warp-fast: a labeled block gives the kind once where the value is built.
const State = enum { idle, running, done };
pub const Job = struct {
    state: State = .idle,
    pub fn make(done: bool) Job {
        var j: Job = .{};
        j.state = blk: {
            if (done) break :blk .done;
            break :blk .idle;
        };
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
