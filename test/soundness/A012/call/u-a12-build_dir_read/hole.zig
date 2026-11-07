// A012 in a build script: the build's own stdin reader handed to another function before it is
// read: that function may make it any reader, so the read is a peer's and the size stays flagged.
const std = @import("std");
fn hand(r: *std.Io.Reader) void {
    std.mem.doNotOptimizeAway(r);
}
pub fn sizes(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    var buf: [64]u8 = undefined;
    var fr = std.Io.File.stdin().reader(io, &buf);
    const r = &fr.interface;
    hand(r);
    const n = try r.takeInt(u32, .little);
    return gpa.alloc(u8, n);
}
