// warp-fast: one function making the state's one transition to a fixed state, called from two
const Phase = enum { idle, running, done };
pub const Job = struct {
    phase: Phase = .running,
    fn finish(j: *Job) void {
        if (j.phase != .running) return;
        j.phase = .done;
    }
    pub fn stop(j: *Job) void {
        j.finish();
    }
    pub fn cancel(j: *Job) void {
        j.finish();
    }
    pub fn label(j: *const Job) []const u8 {
        return switch (j.phase) {
            .idle => "idle",
            .running => "running",
            .done => "done",
        };
    }
};
