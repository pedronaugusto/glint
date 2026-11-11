// twin: an integer given only whole values from elsewhere (its callers' arguments): a value, never a state
pub const Link = struct {
    mode: u8 = 0,
    pub fn open(l: *Link, next: u8) void {
        switch (l.mode) {
            0 => l.mode = next,
            else => {},
        }
    }
    pub fn close(l: *Link, next: u8) void {
        if (l.mode == 1) l.mode = next;
    }
    pub fn label(l: *const Link) []const u8 {
        return switch (l.mode) {
            0 => "idle",
            1 => "open",
            else => "closed",
        };
    }
};
