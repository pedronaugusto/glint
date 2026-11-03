// The state a tagged union: written in two functions, switched on and moved on its own value.
const Phase = union(enum) { idle, running: u32, done };
pub const Job = struct {
    phase: Phase = .idle,
    pub fn reset(j: *Job) void {
        j.phase = .idle;
    }
    pub fn step(j: *Job) void {
        switch (j.phase) {
            .idle => j.phase = .{ .running = 0 },
            .running => j.phase = .done,
            .done => {},
        }
    }
};
