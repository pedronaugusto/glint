// std.mem.asBytes of the record only read; the state written in one function.
const std = @import("std");
const Phase = enum(u8) { idle, running, done };
pub const Job = extern struct {
    phase: Phase = .idle,
    pub fn step(j: *Job) void {
        switch (j.phase) {
            .idle => j.phase = .running,
            .running => j.phase = .done,
            .done => {},
        }
    }
    pub fn code(j: *const Job) u8 {
        return std.mem.asBytes(j)[0];
    }
};
