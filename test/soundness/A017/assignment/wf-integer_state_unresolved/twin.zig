// warp-fast: the same integer given only whole values from elsewhere: a value, no state set
// (A017's ruling, 11-06).
pub const Link = struct {
    mode: u8 = 0,
    pub fn open(l: *Link, given: u8) void {
        switch (l.mode) {
            0 => l.mode = given,
            else => {},
        }
    }
    pub fn close(l: *Link, given: u8) void {
        if (l.mode == 1) l.mode = given;
    }
    pub fn label(l: *const Link) []const u8 {
        return switch (l.mode) {
            0 => "idle",
            1 => "open",
            else => "closed",
        };
    }
};
