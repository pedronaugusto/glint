// matrix: the state loaded and stored by atomics, switched on as loaded
const Phase = enum(u8) { idle, running, done };
pub const Job = struct {
    phase: Phase = .idle,
    pub fn reset(j: *Job) void {
        @atomicStore(Phase, &j.phase, .idle, .release);
    }
    pub fn step(j: *Job) void {
        switch (@atomicLoad(Phase, &j.phase, .acquire)) {
            .idle => @atomicStore(Phase, &j.phase, .running, .release),
            .running => @atomicStore(Phase, &j.phase, .done, .release),
            .done => {},
        }
    }
};
