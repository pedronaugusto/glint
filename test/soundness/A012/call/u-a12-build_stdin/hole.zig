// A012 in a build script: a file made over a descriptor the function is given (a socket's) is no
// source the build opened: what it reads is a peer's, so the size stays flagged.
const std = @import("std");
pub fn sizes(gpa: std.mem.Allocator, io: std.Io, fd: std.Io.File.Handle) ![]u8 {
    var buf: [64]u8 = undefined;
    const sock: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    var fr = sock.reader(io, &buf);
    const r = &fr.interface;
    const n = try r.takeInt(u32, .little);
    return gpa.alloc(u8, n);
}
