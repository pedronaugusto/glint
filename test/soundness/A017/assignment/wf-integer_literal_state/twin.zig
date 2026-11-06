// warp-fast: the same integer reset to a literal but moved on by arithmetic on its own value: a
// counter, no state set (A017's ruling, 11-06: arithmetic on its own value makes it a value).
pub const Link = struct {
    mode: u8 = 0,
    pub fn open(l: *Link) void {
        switch (l.mode) {
            0 => l.mode += 1,
            else => {},
        }
    }
    pub fn close(l: *Link) void {
        if (l.mode == 1) l.mode = 0;
    }
    pub fn label(l: *const Link) []const u8 {
        return switch (l.mode) {
            0 => "idle",
            else => "open",
        };
    }
};
