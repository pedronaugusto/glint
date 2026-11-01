// matrix: the state held as its enum's integer and converted back at each switch on it
const Phase = enum(u8) { idle, running, done };
pub const Job = struct {
    phase: u8 = @backingInt(Phase.idle),
    pub fn reset(j: *Job) void {
        j.phase = @backingInt(Phase.idle);
    }
    pub fn step(j: *Job) void {
        switch (@as(Phase, @fromBackingInt(j.phase))) {
            .idle => j.phase = @backingInt(Phase.running),
            .running => j.phase = @backingInt(Phase.done),
            .done => {},
        }
    }
};
