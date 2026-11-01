// matrix: the state written as part of a whole-record literal, under a switch on it
const Phase = enum { idle, running, done };
pub const Job = struct {
    phase: Phase = .idle,
    ticks: u32 = 0,
    pub fn reset(j: *Job) void {
        j.* = .{};
    }
    pub fn step(j: *Job) void {
        switch (j.phase) {
            .idle => j.* = .{ .phase = .running, .ticks = j.ticks +% 1 },
            .running => j.* = .{ .phase = .done, .ticks = j.ticks +% 1 },
            .done => {},
        }
    }
};
