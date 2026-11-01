// warp-fast: a defer counts runs; the kind is never moved.
const State = enum { idle, running, done };
pub const Job = struct {
    state: State = .idle,
    runs: u32 = 0,
    pub fn run(j: *Job) void {
        defer j.runs += 1;
    }
    pub fn report(j: *const Job) u8 {
        return switch (j.state) {
            .idle => 0,
            .running => 1,
            .done => 2,
        };
    }
};
