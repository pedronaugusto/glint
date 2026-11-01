// warp-fast: a field's handle summed into a local, which a File made from it closes: a release
const std = @import("std");
const Stored = struct { file: std.Io.File, n: u32 };
pub fn store(s: *Stored, f: std.Io.File) void {
    s.file = f;
}
pub fn drop(s: *Stored, io: std.Io) void {
    var fd: std.Io.File.Handle = 0;
    fd += s.file.handle;
    const g: std.Io.File = .{ .handle = fd };
    g.close(io);
}
