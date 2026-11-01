// warp-fast: a labeled block's result that is a parameter gives the field a borrow.
const std = @import("std");
const Stored = struct { file: std.Io.File, n: u32 };
pub fn store(s: *Stored, f: std.Io.File) void {
    s.file = blk: {
        s.n += 1;
        break :blk f;
    };
}
