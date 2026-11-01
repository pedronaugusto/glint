// warp-fast: the read through @field comes before the release.
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !std.Io.File.Handle {
    const file = try dir.openFile(io, "a", .{});
    const h = @field(file, "handle");
    file.close(io);
    return h;
}
