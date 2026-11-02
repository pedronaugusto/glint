// A program function returning std.mem.asBytes of its parameter is a view as asBytes is: bytes copied through it are a second writer of the state.
const std = @import("std");
const Phase = enum(u8) { idle, running, done };
fn bytesOf(j: *Job) []u8 {
    return std.mem.asBytes(j);
}
pub const Job = extern struct {
    phase: Phase = .idle,
    pub fn step(j: *Job) void {
        switch (j.phase) {
            .idle => j.phase = .running,
            .running => j.phase = .done,
            .done => {},
        }
    }
    pub fn load(j: *Job, bytes: []const u8) void {
        @memcpy(bytesOf(j), bytes);
    }
};
