// twin: one writer only; the state's type is an enum std makes (std.meta.FieldEnum): written in two functions, switched on, moved on its value
const std = @import("std");
const Steps = struct { idle: void, running: void, done: void };
const Phase = std.meta.FieldEnum(Steps);
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
