// A whole holder copied from another record under a switch: the state it carries was chosen where it was made.
const Phase = enum { idle, running, done };
pub const Job = struct {
    phase: Phase = .idle,
    fn at(p: Phase) Job {
        return .{ .phase = p };
    }
    pub fn make(p: Phase) Job {
        return at(p);
    }
    pub fn label(j: *const Job) u8 {
        return switch (j.phase) {
            .idle => 0,
            .running => 1,
            .done => 2,
        };
    }
};
