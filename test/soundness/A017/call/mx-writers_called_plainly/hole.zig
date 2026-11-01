// matrix: the state's writers called as free functions from the prongs of a switch on it
const Phase = enum { idle, running, done };
pub const Job = struct {
    phase: Phase = .idle,
};
fn start(j: *Job) void {
    j.phase = .running;
}
fn finish(j: *Job) void {
    j.phase = .done;
}
pub fn step(j: *Job) void {
    switch (j.phase) {
        .idle => start(j),
        .running => finish(j),
        .done => {},
    }
}
