// A012 in a build script: a size read from the output of a child the build ran is the
// operator's, no peer's (Taint.localRead): a reader over its bytes holds their fact.
const std = @import("std");
pub fn sizes(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    const ran = try std.process.run(gpa, io, .{ .argv = &.{ "git", "rev-list", "--count", "HEAD" }, .stdout_limit = .limited(64) });
    var r: std.Io.Reader = .fixed(ran.stdout);
    const n = try r.takeInt(u32, .little);
    return gpa.alloc(u8, n);
}
