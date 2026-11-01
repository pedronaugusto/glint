// warp-fast: an array field of resources held by value, an element opened and stored into it
const std = @import("std");
const Stored = struct { files: [2]std.Io.File, n: u32 };
pub fn store(s: *Stored, dir: std.Io.Dir, io: std.Io) !void {
    s.files[0] = try dir.openFile(io, "a", .{});
}
