// A012 in a build script: a size read from a file of the tree (a directory's read) is the
// operator's, no peer's (Taint.localRead): a reader over its bytes holds their fact.
const std = @import("std");
pub fn sizes(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "sizes.bin", gpa, .limited(64));
    var r: std.Io.Reader = .fixed(bytes);
    const n = try r.takeInt(u32, .little);
    return gpa.alloc(u8, n);
}
