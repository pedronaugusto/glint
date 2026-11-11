// A017: an integer state given its literals through labeled blocks: two writers, moved under a switch on it, switched on
pub const Link = struct {
    mode: u8 = 0,
    pub fn open(l: *Link) void {
        switch (l.mode) {
            0 => l.mode = blk: {
                break :blk 1;
            },
            else => {},
        }
    }
    pub fn close(l: *Link) void {
        if (l.mode == 1) l.mode = blk: {
            break :blk 2;
        };
    }
    pub fn label(l: *const Link) []const u8 {
        return switch (l.mode) {
            0 => "idle",
            1 => "open",
            else => "closed",
        };
    }
};
