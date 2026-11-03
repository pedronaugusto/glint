// warp-fast: a Dir made of another file's field's handle kept as another file's union's lent tag, which nothing releases
const std = @import("std");
const S = @import("before.zig").S;
const Parent = @import("before.zig").Parent;
fn close(p: *Parent, io: std.Io) void {
    _ = io;
    switch (p.*) {
        .owned => {},
        .lent => {},
    }
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
pub fn lend(s: *S, p: *Parent, io: std.Io) void {
    adopt(p, .{ .handle = s.d.handle });
    close(p, io);
}
