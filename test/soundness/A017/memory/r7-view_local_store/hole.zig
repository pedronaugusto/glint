// A second writer stores the state's byte through a local std.mem.asBytes view of the record.
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
    pub fn force(j: *Job, code: u8) void {
        const bytes = std.mem.asBytes(j);
        bytes[0] = code;
    }
};
