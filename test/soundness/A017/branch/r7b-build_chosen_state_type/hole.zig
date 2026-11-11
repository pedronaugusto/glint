// A017: the state's type is one of two enums chosen per build: written in two functions, switched on, moved on its value
const builtin = @import("builtin");
const Phase = if (builtin.mode == .debug) enum { idle, running, done, checked } else enum { idle, running, done };
pub const Job = struct {
    phase: Phase = .idle,
    pub fn reset(j: *Job) void {
        j.phase = .idle;
    }
    pub fn step(j: *Job) void {
        switch (j.phase) {
            .idle => j.phase = .running,
            .running => j.phase = .done,
            else => {},
        }
    }
};
