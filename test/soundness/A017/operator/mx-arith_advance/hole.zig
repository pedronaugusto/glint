// matrix: the state moved on its own value by arithmetic on its integer, switched on elsewhere
const Phase = enum { idle, running, done };
pub const Job = struct {
    phase: Phase = .idle,
    pub fn reset(j: *Job) void {
        j.phase = .idle;
    }
    pub fn advance(j: *Job) void {
        j.phase = @fromBackingInt(@intCast((@as(u8, @backingInt(j.phase)) + 1) % 3));
    }
    pub fn label(j: *const Job) []const u8 {
        return switch (j.phase) {
            .idle => "idle",
            .running => "running",
            .done => "done",
        };
    }
};
