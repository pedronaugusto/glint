// A std.atomic.Value of an enum stored in one function only, and switched on.
const std = @import("std");
const Phase = enum(u8) { idle, running, done };
pub const Job = struct {
    phase: std.atomic.Value(Phase) = .init(.idle),
    pub fn finish(j: *Job) void {
        j.phase.store(.done, .release);
    }
    pub fn label(j: *const Job) u8 {
        return switch (j.phase.load(.acquire)) {
            .idle => 0,
            .running => 1,
            .done => 2,
        };
    }
};
