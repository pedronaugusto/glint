// Bytes copied through the wrapper view of another record; the state written in one function.
const std = @import("std");
const Phase = enum(u8) { idle, running, done };
pub const Note = extern struct { code: u8 = 0 };
fn bytesOf(n: *Note) []u8 {
    return std.mem.asBytes(n);
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
    pub fn load(n: *Note, bytes: []const u8) void {
        @memcpy(bytesOf(n), bytes);
    }
};
