// warp-fast: the state only loaded atomically.
const State = enum { idle, running, done };
pub const Job = struct {
    state: State = .idle,
    pub fn busy(j: *const Job) bool {
        return @atomicLoad(State, &j.state, .acquire) == .running;
    }
    pub fn report(j: *const Job) u8 {
        return switch (j.state) {
            .idle => 0,
            .running => 1,
            .done => 2,
        };
    }
};
