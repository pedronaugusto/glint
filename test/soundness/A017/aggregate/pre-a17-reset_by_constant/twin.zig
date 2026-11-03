// One function writes the state; reset clears another field from a constant.
const Phase = enum { idle, running, done };
pub const Job = struct {
    phase: Phase = .idle,
    count: u32 = 0,
    pub const zero: u32 = 0;
    pub fn start(j: *Job) void {
        switch (j.phase) {
            .idle => j.phase = .running,
            else => {},
        }
    }
    pub fn reset(j: *Job) void {
        switch (j.phase) {
            .done => j.count = zero,
            else => {},
        }
    }
};
