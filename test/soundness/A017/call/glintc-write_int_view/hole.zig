// A second writer writes the record's bytes by std.mem.writeInt.
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
        std.mem.writeInt(u8, std.mem.asBytes(j), code, .little);
    }
};
