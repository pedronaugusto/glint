// A017: an integer state written only with named constants (const idle: u8 = 0 ...): a literal choice by meaning, two writers, moved under a switch on it, switched on
const idle: u8 = 0;
const open_mode: u8 = 1;
const closed: u8 = 2;
pub const Link = struct {
    mode: u8 = idle,
    pub fn open(l: *Link) void {
        switch (l.mode) {
            idle => l.mode = open_mode,
            else => {},
        }
    }
    pub fn close(l: *Link) void {
        if (l.mode == open_mode) l.mode = closed;
    }
    pub fn label(l: *const Link) []const u8 {
        return switch (l.mode) {
            idle => "idle",
            open_mode => "open",
            else => "closed",
        };
    }
};
