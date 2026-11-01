// warp-fast: the state given an if expression on its own value, in two functions.
const State = enum { idle, running, done };
pub const Job = struct {
    state: State = .idle,
    pub fn start(j: *Job) void {
        j.state = if (j.state == .idle) .running else j.state;
    }
    pub fn finish(j: *Job) void {
        j.state = switch (j.state) {
            .running => .done,
            else => |s| s,
        };
    }
    pub fn report(j: *const Job) u8 {
        return switch (j.state) {
            .idle => 0,
            .running => 1,
            .done => 2,
        };
    }
};
