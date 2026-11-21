// Z058: a file created without `.read = true` held in a local, then stat through it: Windows
// refuses the stat, as the handle lacks FILE_READ_ATTRIBUTES.
const std = @import("std");
pub fn size(dir: std.Io.Dir, io: std.Io) !u64 {
    const file = try dir.createFile(io, "out", .{ .truncate = false });
    defer file.close(io);
    return (try file.stat(io)).size;
}
