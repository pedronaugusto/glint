// warp-fast: one function moving a union to one fixed tag, its payload the caller's, called from two
const Phase = union(enum) { idle, running, done: u32 };
pub const Job = struct {
    phase: Phase = .running,
    fn finish(j: *Job, code: u32) void {
        if (j.phase != .running) return;
        j.phase = .{ .done = code };
    }
    pub fn stop(j: *Job) void {
        j.finish(0);
    }
    pub fn cancel(j: *Job) void {
        j.finish(1);
    }
    pub fn label(j: *const Job) []const u8 {
        return switch (j.phase) {
            .idle => "idle",
            .running => "running",
            .done => "done",
        };
    }
};
