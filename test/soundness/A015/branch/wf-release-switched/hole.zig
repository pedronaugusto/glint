// warp-fast: the field a switch prong gives and that is released is an owner held by hand.
const std = @import("std");
const Stored = struct { file: std.Io.File, n: u32 };
pub fn store(s: *Stored, f: std.Io.File) void {
    s.file = f;
}
pub fn close(s: *Stored, other: std.Io.File, which: u1, io: std.Io) void {
    const chosen = switch (which) {
        0 => s.file,
        1 => other,
    };
    chosen.close(io);
}
