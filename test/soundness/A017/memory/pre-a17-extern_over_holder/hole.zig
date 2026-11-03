// Code the program does not hold writes a whole record through its pointer: a second writer of the state, as @memcpy of bytes over it is.
const Phase = enum(u8) { idle, running, done };
extern fn fill(j: *Job) void;
pub const Job = extern struct {
    phase: Phase = .idle,
    pub fn step(j: *Job) void {
        switch (j.phase) {
            .idle => j.phase = .running,
            .running => j.phase = .done,
            .done => {},
        }
    }
    pub fn load(j: *Job) void {
        fill(j);
    }
};
