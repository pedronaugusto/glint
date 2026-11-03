// Writes guarded by predicates that read the state: two functions move it on its own value.
const Phase = enum { idle, running, done };
pub const Job = struct {
    phase: Phase = .idle,
    fn idle(j: *const Job) bool {
        return j.phase == .idle;
    }
    fn running(j: *const Job) bool {
        return j.phase == .running;
    }
    pub fn start(j: *Job) void {
        if (j.idle()) j.phase = .running;
    }
    pub fn stop(j: *Job) void {
        if (j.running()) j.phase = .done;
    }
    pub fn label(j: *const Job) u8 {
        return switch (j.phase) {
            .idle => 0,
            .running => 1,
            .done => 2,
        };
    }
};
