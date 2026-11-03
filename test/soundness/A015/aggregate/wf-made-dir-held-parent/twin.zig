// warp-fast: a Dir made of another file's field's handle kept as a union's lent tag, read back by a getter and only its handle used
const std = @import("std");
const S = @import("before.zig").S;
const Parent = @import("before.zig").Parent;
fn get(p: *Parent) ?std.Io.Dir {
    return switch (p.*) {
        .owned => null,
        .lent => |d| d,
    };
}
fn release(io: std.Io, handle: std.Io.File.Handle) void {
    const dir: std.Io.Dir = .{ .handle = handle };
    dir.close(io);
}
pub fn finish(owned: std.Io.Dir, io: std.Io) void {
    release(io, owned.handle);
}
fn adopt(p: *Parent, dir: std.Io.Dir) void {
    p.* = .{ .lent = dir };
}
pub fn lend(s: *S, p: *Parent, io: std.Io) ?std.Io.File.Handle {
    adopt(p, .{ .handle = s.d.handle });
    _ = io;
    const held = get(p);
    if (held) |d| return d.handle;
    return null;
}
