// twin: the same bytes of a plain record
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
    pub fn force(j: *Job, code: *const [1]u8) void {
        for (std.mem.asBytes(&j.pad), code) |*d, s| d.* = s;
    }
};
