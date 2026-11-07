// A012 in a build script: stdin's file reassigned to one over a descriptor the function is given
// (a socket's) before it is read: no source the build opened, so the size stays flagged.
const std = @import("std");
pub fn sizes(gpa: std.mem.Allocator, io: std.Io, fd: std.Io.File.Handle) ![]u8 {
    var buf: [64]u8 = undefined;
    var file = std.Io.File.stdin();
    file = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    var fr = file.reader(io, &buf);
    const n = try fr.interface.takeInt(u32, .little);
    return gpa.alloc(u8, n);
}
