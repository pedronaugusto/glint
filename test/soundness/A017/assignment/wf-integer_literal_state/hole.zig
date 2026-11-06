// warp-fast: an integer whose writes give it literal choices (0, 1, 2), written in two functions,
// moved under a switch on it and switched on: a state set kept by hand (A017's ruling, 11-06).
pub const Link = struct {
    mode: u8 = 0,
    pub fn open(l: *Link) void {
        switch (l.mode) {
            0 => l.mode = 1,
            else => {},
        }
    }
    pub fn close(l: *Link) void {
        if (l.mode == 1) l.mode = 2;
    }
    pub fn label(l: *const Link) []const u8 {
        return switch (l.mode) {
            0 => "idle",
            1 => "open",
            else => "closed",
        };
    }
};
