// A012 in a build script: a size read from the build's own stdin is the operator's, whoever runs
// the build, no peer's (Taint.localRead).
const std = @import("std");
pub fn sizes(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    var buf: [64]u8 = undefined;
    var fr = std.Io.File.stdin().reader(io, &buf);
    const r = &fr.interface;
    const n = try r.takeInt(u32, .little);
    return gpa.alloc(u8, n);
}
