// Writes guarded by a predicate on another field.
const Phase = enum { idle, running, done };
pub const Job = struct {
    phase: Phase = .idle,
    ready: bool = false,
    fn isReady(j: *const Job) bool {
        return j.ready;
    }
    pub fn start(j: *Job) void {
        if (j.isReady()) j.phase = .running;
    }
    pub fn stop(j: *Job) void {
        if (j.isReady()) j.phase = .done;
    }
    pub fn label(j: *const Job) u8 {
        return switch (j.phase) {
            .idle => 0,
            .running => 1,
            .done => 2,
        };
    }
};
