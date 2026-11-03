// The state held in a std.atomic.Value of its enum: loaded, switched on and stored in two functions.
const std = @import("std");
const Phase = enum(u8) { idle, running, done };
pub const Job = struct {
    phase: std.atomic.Value(Phase) = .init(.idle),
    pub fn reset(j: *Job) void {
        j.phase.store(.idle, .release);
    }
    pub fn step(j: *Job) void {
        switch (j.phase.load(.acquire)) {
            .idle => j.phase.store(.running, .release),
            .running => j.phase.store(.done, .release),
            .done => {},
        }
    }
};
