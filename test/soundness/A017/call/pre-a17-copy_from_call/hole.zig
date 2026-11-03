// A whole holder stored from a call that builds it with the next state, under a switch on the state.
const Phase = enum { idle, running, done };
pub const Job = struct {
    phase: Phase = .idle,
    fn at(p: Phase) Job {
        return .{ .phase = p };
    }
    pub fn start(j: *Job) void {
        switch (j.phase) {
            .idle => j.* = at(.running),
            else => {},
        }
    }
    pub fn stop(j: *Job) void {
        switch (j.phase) {
            .running => j.* = at(.done),
            else => {},
        }
    }
};
