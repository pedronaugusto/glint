// twin: one writer only; the state's type read off a union by reflection (@typeInfo ... tag_type): written in two functions, switched on, moved on its value
const Shape = union(enum) { idle: void, running: u32, done: void };
const Phase = @typeInfo(Shape).@"union".tag_type.?;
pub const Job = struct {
    phase: Phase = .idle,
    pub fn step(j: *Job) void {
        switch (j.phase) {
            .idle => j.phase = .running,
            .running => j.phase = .done,
            .done => {},
        }
    }
};
