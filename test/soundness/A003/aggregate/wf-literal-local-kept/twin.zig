// warp-fast: a copy put in a literal a local holds, whose field the callee only reads: lent, the caller's close is the one release
const std = @import("std");
const Box = struct { f: std.Io.File };
fn reads(f: std.Io.File) std.Io.File.Handle {
    const b: Box = .{ .f = f };
    return b.f.handle;
}
pub fn run(dir: std.Io.Dir, io: std.Io) !void {
    const file = try dir.openFile(io, "a", .{});
    defer file.close(io);
    _ = reads(file);
}
