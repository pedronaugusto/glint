// A017: an integer state given its literal nine choices deep (if within if): two writers, moved under a switch on it, switched on
pub const Link = struct {
    mode: u8 = 0,
    depth: u8 = 0,
    pub fn open(l: *Link, f: [9]bool) void {
        switch (l.mode) {
            0 => l.mode = if (f[0]) (if (f[1]) (if (f[2]) (if (f[3]) (if (f[4]) (if (f[5]) (if (f[6]) (if (f[7]) (if (f[8]) 1 else l.depth) else l.depth) else l.depth) else l.depth) else l.depth) else l.depth) else l.depth) else l.depth) else l.depth,
            else => {},
        }
    }
    pub fn close(l: *Link, f: [9]bool) void {
        if (l.mode == 1) l.mode = if (f[0]) (if (f[1]) (if (f[2]) (if (f[3]) (if (f[4]) (if (f[5]) (if (f[6]) (if (f[7]) (if (f[8]) 2 else l.depth) else l.depth) else l.depth) else l.depth) else l.depth) else l.depth) else l.depth) else l.depth) else l.depth;
    }
    pub fn label(l: *const Link) []const u8 {
        return switch (l.mode) {
            0 => "idle",
            1 => "open",
            else => "closed",
        };
    }
};
