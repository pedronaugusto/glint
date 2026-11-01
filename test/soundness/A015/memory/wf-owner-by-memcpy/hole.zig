// warp-fast: an opened file's bytes copied into the field by @memcpy make it an owner.
const std = @import("std");
const Stored = struct { file: std.Io.File, n: u32 };
pub fn store(s: *Stored, dir: std.Io.Dir, io: std.Io) !void {
    const opened = try dir.openFile(io, "a", .{});
    @memcpy(std.mem.asBytes(&s.file), std.mem.asBytes(&opened));
}
