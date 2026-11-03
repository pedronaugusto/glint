// The state read into a destructure's local and switched on there, moved under that switch.
const Phase = enum { idle, running, done };
pub const Job = struct {
    phase: Phase = .idle,
    n: u32 = 0,
    pub fn step(j: *Job) void {
        const now, const n = .{ j.phase, j.n };
        _ = n;
        switch (now) {
            .idle => j.phase = .running,
            .running => j.phase = .done,
            .done => {},
        }
    }
    pub fn reset(j: *Job) void {
        j.phase = .idle;
    }
};
