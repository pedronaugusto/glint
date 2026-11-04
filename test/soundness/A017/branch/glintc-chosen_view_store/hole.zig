// A second writer stores the state's byte through a constant chosen between two views of the record.
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
    pub fn force(j: *Job, code: u8, whole: bool) void {
        const bytes: []u8 = if (whole) std.mem.asBytes(j) else std.mem.asBytes(j)[0..1];
        bytes[0] = code;
    }
};
