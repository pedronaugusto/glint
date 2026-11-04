// twin: the same bytes of a plain field
const std = @import("std");
const Phase = enum(u8) { idle, running, done };
pub const Job = extern struct {
    pad: u8 = 0,
    phase: Phase = .idle,
    pub fn step(j: *Job) void {
        switch (j.phase) {
            .idle => j.phase = .running,
            .running => j.phase = .done,
            .done => {},
        }
    }
    pub fn force(j: *Job, code: u8, whole: bool) void {
        const bytes: []u8 = if (whole) std.mem.asBytes(&j.pad) else std.mem.asBytes(&j.pad)[0..1];
        bytes[0] = code;
    }
};
