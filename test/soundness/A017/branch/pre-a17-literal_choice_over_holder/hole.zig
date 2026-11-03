// A choice of record literals stored over the holder, chosen on the state itself: moved on its own value.
const Phase = enum { idle, running, done };
pub const Job = struct {
    phase: Phase = .idle,
    pub fn start(j: *Job) void {
        switch (j.phase) {
            .idle => j.phase = .running,
            else => {},
        }
    }
    pub fn settle(j: *Job) void {
        j.* = if (j.phase == .done) .{} else .{ .phase = .running };
    }
};
