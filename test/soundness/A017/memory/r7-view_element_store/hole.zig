// A second writer stores the state's byte through std.mem.asBytes of the record, as @memcpy(std.mem.asBytes(j), ...) writes it.
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
        std.mem.asBytes(j)[0] = code;
    }
};
