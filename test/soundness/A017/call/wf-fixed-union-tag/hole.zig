// warp-fast: one function moving a union to a tag its caller chooses, called from two
const Phase = union(enum) { idle, running, done: u32, failed: u32 };
pub const Job = struct {
    phase: Phase = .running,
    fn finish(j: *Job, ok: bool, code: u32) void {
        if (j.phase != .running) return;
        j.phase = if (ok) .{ .done = code } else .{ .failed = code };
    }
    pub fn stop(j: *Job) void {
        j.finish(true, 0);
    }
    pub fn cancel(j: *Job) void {
        j.finish(false, 1);
    }
    pub fn label(j: *const Job) []const u8 {
        return switch (j.phase) {
            .idle => "idle",
            .running => "running",
            .done => "done",
            .failed => "failed",
        };
    }
};
