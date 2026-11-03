// A switch before the write that leaves on no state: the write is unconditional.
const Phase = enum { idle, running, done };
pub const Job = struct {
    phase: Phase = .idle,
    n: u32 = 0,
    pub fn start(j: *Job) void {
        switch (j.phase) {
            .idle => j.n += 1,
            else => {},
        }
        j.phase = .running;
    }
    pub fn stop(j: *Job) void {
        switch (j.phase) {
            .running => j.n += 1,
            else => {},
        }
        j.phase = .done;
    }
};
