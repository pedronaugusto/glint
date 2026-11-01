// warp-fast: a method given the record's address under a switch on its state writes only its count.
const State = enum { idle, running, done };
pub const Job = struct {
    state: State = .idle,
    ticks: u32 = 0,
    pub fn start(j: *Job) void {
        j.state = .running;
    }
    pub fn finish(j: *Job) void {
        j.state = .done;
    }
    pub fn tick(j: *Job) void {
        j.ticks +%= 1;
    }
    pub fn step(j: *Job) void {
        switch (j.state) {
            .running => j.tick(),
            else => {},
        }
    }
};
