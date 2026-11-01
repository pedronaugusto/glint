// warp-fast: a copy put in a literal a local holds, whose field the callee stores in a lasting holder that closes it: kept, so the caller's close may be a second one
const std = @import("std");
const Box = struct { f: std.Io.File };
const Holder = struct {
    f: std.Io.File,
    fn drop(h: *Holder, io: std.Io) void {
        h.f.close(io);
    }
};
fn keeps(h: *Holder, f: std.Io.File) void {
    const b: Box = .{ .f = f };
    h.f = b.f;
}
pub fn run(dir: std.Io.Dir, io: std.Io, h: *Holder) !void {
    const file = try dir.openFile(io, "a", .{});
    defer file.close(io);
    keeps(h, file);
}
