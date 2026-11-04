// A second writer hands the record's bytes to a helper that stores into its slice.
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
    fn put(b: []u8, code: u8) void {
        b[0] = code;
    }
    pub fn force(j: *Job, code: u8) void {
        put(std.mem.asBytes(j), code);
    }
};
