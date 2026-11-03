// Code the program does not hold reads a record through a const pointer; the state written in one function.
const Phase = enum(u8) { idle, running, done };
extern fn show(j: *const Job) void;
pub const Job = extern struct {
    phase: Phase = .idle,
    pub fn step(j: *Job) void {
        switch (j.phase) {
            .idle => j.phase = .running,
            .running => j.phase = .done,
            .done => {},
        }
    }
    pub fn print(j: *const Job) void {
        show(j);
    }
};
