// An integer state switched on as an integer and moved under that switch, in two writers.
pub const Job = struct {
    step: u8 = 0,
    pub fn reset(j: *Job) void {
        j.step = 0;
    }
    pub fn advance(j: *Job) void {
        switch (j.step) {
            0 => j.step = 1,
            1 => j.step = 2,
            else => {},
        }
    }
};
