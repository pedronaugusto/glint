// An integer switched on and written in one function only.
pub const Job = struct {
    step: u8 = 0,
    pub fn advance(j: *Job) void {
        switch (j.step) {
            0 => j.step = 1,
            1 => j.step = 2,
            else => {},
        }
    }
};
