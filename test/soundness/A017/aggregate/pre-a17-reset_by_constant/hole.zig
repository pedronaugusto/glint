// A whole holder stored from a named constant resets the state as `j.* = .{}` does: reset moves done -> idle under a switch.
const Phase = enum { idle, running, done };
pub const Job = struct {
    phase: Phase = .idle,
    pub const empty: Job = .{};
    pub fn start(j: *Job) void {
        switch (j.phase) {
            .idle => j.phase = .running,
            else => {},
        }
    }
    pub fn reset(j: *Job) void {
        switch (j.phase) {
            .done => j.* = empty,
            else => {},
        }
    }
};
