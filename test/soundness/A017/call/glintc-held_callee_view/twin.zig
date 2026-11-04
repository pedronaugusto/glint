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
    fn put(b: []u8, code: u8) void {
        b[0] = code;
    }
    pub fn force(j: *Job, code: u8) void {
        put(std.mem.asBytes(&j.pad), code);
    }
};
