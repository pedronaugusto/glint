// A switch that leaves on every other state guards the write after it, as `if (j.phase != .idle) return;` does.
const Phase = enum { idle, running, done };
pub const Job = struct {
    phase: Phase = .idle,
    pub fn start(j: *Job) void {
        switch (j.phase) {
            .idle => {},
            else => return,
        }
        j.phase = .running;
    }
    pub fn stop(j: *Job) void {
        switch (j.phase) {
            .running => {},
            else => return,
        }
        j.phase = .done;
    }
};
