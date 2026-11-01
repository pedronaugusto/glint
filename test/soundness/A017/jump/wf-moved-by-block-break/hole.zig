// warp-fast: the state given a labeled block's result, chosen by a switch on it, in two functions.
const State = enum { idle, running, done };
pub const Job = struct {
    state: State = .idle,
    pub fn start(j: *Job) void {
        j.state = blk: {
            if (j.state == .idle) break :blk .running;
            break :blk j.state;
        };
    }
    pub fn finish(j: *Job) void {
        j.state = blk: {
            if (j.state == .running) break :blk .done;
            break :blk j.state;
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
