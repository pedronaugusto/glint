// warp-fast: a pointer to the state is only read.
const State = enum { idle, running, done };
pub const Job = struct {
    state: State = .idle,
    pub fn busy(j: *const Job) bool {
        const s = &j.state;
        return s.* == .running;
    }
    pub fn report(j: *const Job) u8 {
        return switch (j.state) {
            .idle => 0,
            .running => 1,
            .done => 2,
        };
    }
};
