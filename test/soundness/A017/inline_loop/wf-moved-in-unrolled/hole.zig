// warp-fast: an inline for moves the state to each next value under a condition on it, in two
// functions.
const State = enum { idle, running, done };
pub const Job = struct {
    state: State = .idle,
    pub fn start(j: *Job) void {
        inline for (.{ .{ State.idle, State.running } }) |step| {
            if (j.state == step[0]) j.state = step[1];
        }
    }
    pub fn finish(j: *Job) void {
        inline for (.{ .{ State.running, State.done } }) |step| {
            if (j.state == step[0]) j.state = step[1];
        }
    }
    pub fn report(j: *const Job) u8 {
        return switch (j.state) {
            .idle => 0,
            .running => 1,
            .done => 2,
        };
    }
};
