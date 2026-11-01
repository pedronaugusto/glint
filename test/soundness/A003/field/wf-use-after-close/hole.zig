// warp-fast: a read of the owner through @field after its release.
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !std.Io.File.Handle {
    const file = try dir.openFile(io, "a", .{});
    file.close(io);
    return @field(file, "handle");
}
