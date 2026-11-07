// A012 in the program's own file: a size read from stdin is a peer's (whoever pipes into the
// program), where a build script's is the operator's (call/u-a12-build_stdin's twin).
const std = @import("std");
pub fn sizes(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    var buf: [64]u8 = undefined;
    var fr = std.Io.File.stdin().reader(io, &buf);
    const r = &fr.interface;
    const n = try r.takeInt(u32, .little);
    return gpa.alloc(u8, n);
}
