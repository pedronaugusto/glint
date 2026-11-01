// warp-fast: the field given a labeled block's result and released is an owner held by hand.
const std = @import("std");
const Stored = struct { file: std.Io.File, n: u32 };
pub fn store(s: *Stored, f: std.Io.File) void {
    s.file = f;
}
pub fn close(s: *Stored, io: std.Io) void {
    const chosen = blk: {
        s.n += 1;
        break :blk s.file;
    };
    chosen.close(io);
}
