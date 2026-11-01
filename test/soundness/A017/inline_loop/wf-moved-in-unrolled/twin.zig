// warp-fast: an inline for counts each kind; nothing moves the state.
const State = enum { idle, running, done };
pub const Job = struct {
    state: State = .idle,
    pub fn known(j: *const Job) u8 {
        var n: u8 = 0;
        inline for (.{ State.idle, State.running, State.done }) |s| {
            if (j.state == s) n += 1;
        }
        return n;
    }
    pub fn report(j: *const Job) u8 {
        return switch (j.state) {
            .idle => 0,
            .running => 1,
            .done => 2,
        };
    }
};
