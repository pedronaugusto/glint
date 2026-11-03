// A tagged union written in one function, switched on.
const Phase = union(enum) { idle, running: u32, done };
pub const Job = struct {
    phase: Phase = .idle,
    pub fn finish(j: *Job) void {
        j.phase = .done;
    }
    pub fn label(j: *const Job) u8 {
        return switch (j.phase) {
            .idle => 0,
            .running => 1,
            .done => 2,
        };
    }
};
