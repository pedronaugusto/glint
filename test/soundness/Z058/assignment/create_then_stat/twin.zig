// Z058 twin: created with `.read = true`, so the stat is the handle's to make.
const std = @import("std");
pub fn size(dir: std.Io.Dir, io: std.Io) !u64 {
    const file = try dir.createFile(io, "out", .{ .truncate = false, .read = true });
    defer file.close(io);
    return (try file.stat(io)).size;
}
