// One setter making one fixed transition, called from two.
const Phase = enum { idle, running, done };
pub const Job = struct {
    phase: Phase = .running,
    fn go(j: *Job) void {
        j.phase = .done;
    }
    pub fn stop(j: *Job) void {
        switch (j.phase) {
            .running => j.go(),
            else => {},
        }
    }
    pub fn cancel(j: *Job) void {
        switch (j.phase) {
            .running => j.go(),
            else => {},
        }
    }
};
