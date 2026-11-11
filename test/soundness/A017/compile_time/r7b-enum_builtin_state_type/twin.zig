// twin: one writer only; the state's type made by @Enum: written in two functions, switched on, moved on its value
const Phase = @Enum(u8, .exhaustive, &.{ "idle", "running", "done" }, &.{ 0, 1, 2 });
pub const Job = struct {
    phase: Phase = .idle,
    pub fn step(j: *Job) void {
        switch (j.phase) {
            .idle => j.phase = .running,
            .running => j.phase = .done,
            .done => {},
        }
    }
};
