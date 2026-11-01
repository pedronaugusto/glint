// matrix: the state written by destructures, one under a switch on it
const Phase = enum { idle, running, done };
pub const Job = struct {
    phase: Phase = .idle,
    ticks: u32 = 0,
    pub fn reset(j: *Job) void {
        j.phase, j.ticks = .{ .idle, 0 };
    }
    pub fn step(j: *Job) void {
        switch (j.phase) {
            .idle => {
                j.phase, j.ticks = .{ .running, j.ticks +% 1 };
            },
            .running => {
                j.phase, j.ticks = .{ .done, j.ticks +% 1 };
            },
            .done => {},
        }
    }
};
