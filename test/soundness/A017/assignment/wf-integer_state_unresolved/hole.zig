// warp-fast: an integer state written with an enum's integer whose enum glint cannot resolve
// (`builtin`'s, a per-build file), in two functions, moved under a switch on it and switched on:
// whether the program gives it a literal choice is not known, so it is undecided, never a value
// (A017's ruling, 11-06).
const builtin = @import("builtin");
pub const Link = struct {
    mode: u8 = 0,
    pub fn open(l: *Link) void {
        switch (l.mode) {
            0 => l.mode = @intFromEnum(builtin.mode),
            else => {},
        }
    }
    pub fn close(l: *Link) void {
        if (l.mode == 1) l.mode = @intFromEnum(builtin.cpu.arch);
    }
    pub fn label(l: *const Link) []const u8 {
        return switch (l.mode) {
            0 => "idle",
            1 => "open",
            else => "closed",
        };
    }
};
