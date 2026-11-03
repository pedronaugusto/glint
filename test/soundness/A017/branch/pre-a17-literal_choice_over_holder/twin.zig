// A choice of record literals stored over another record type, chosen on a flag; the state written in one function.
const Phase = enum { idle, running, done };
pub const Note = struct { code: u8 = 0 };
pub const Job = struct {
    phase: Phase = .idle,
    pub fn start(j: *Job) void {
        switch (j.phase) {
            .idle => j.phase = .running,
            else => {},
        }
    }
};
pub fn settle(n: *Note, flag: bool) void {
    n.* = if (flag) .{} else .{ .code = 1 };
}
