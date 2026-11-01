// matrix: each transition guarded by a return on the state before it, the state switched on elsewhere
const Phase = enum { idle, running, done };
pub const Job = struct {
    phase: Phase = .idle,
    pub fn start(j: *Job) void {
        if (j.phase != .idle) return;
        j.phase = .running;
    }
    pub fn finish(j: *Job) void {
        if (j.phase != .running) return;
        j.phase = .done;
    }
    pub fn label(j: *const Job) []const u8 {
        return switch (j.phase) {
            .idle => "idle",
            .running => "running",
            .done => "done",
        };
    }
};
