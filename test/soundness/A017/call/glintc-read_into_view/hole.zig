// A second writer reads input straight into the record's bytes.
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
    pub fn force(j: *Job, r: *std.Io.Reader) !void {
        try r.readSliceAll(std.mem.asBytes(j));
    }
};
