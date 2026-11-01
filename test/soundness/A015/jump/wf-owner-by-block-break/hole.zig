// warp-fast: the field is given an opened file as a labeled block's result: an owner.
const std = @import("std");
const Stored = struct { file: std.Io.File, n: u32 };
pub fn store(s: *Stored, dir: std.Io.Dir, io: std.Io) !void {
    s.file = blk: {
        const opened = try dir.openFile(io, "a", .{});
        break :blk opened;
    };
}
