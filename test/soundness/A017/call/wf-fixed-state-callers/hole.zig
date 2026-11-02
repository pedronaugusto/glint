// warp-fast: one mover guarded on the state, each caller choosing the state it moves to
const Phase = enum { idle, running, done };
pub const Job = struct {
    phase: Phase = .idle,
    fn move(j: *Job, from: Phase, to: Phase) void {
        if (j.phase != from) return;
        j.phase = to;
    }
    pub fn start(j: *Job) void {
        j.move(.idle, .running);
    }
    pub fn finish(j: *Job) void {
        j.move(.running, .done);
    }
    pub fn label(j: *const Job) []const u8 {
        return switch (j.phase) {
            .idle => "idle",
            .running => "running",
            .done => "done",
        };
    }
};
