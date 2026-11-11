// twin: one writer only; the state's type is a union's tag (std.meta.Tag): written in two functions, switched on, moved on its value
const std = @import("std");
const Shape = union(enum) { idle: void, running: u32, done: void };
const Phase = std.meta.Tag(Shape);
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
