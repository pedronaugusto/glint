// glint-c: a comparison and a format into a fixed buffer pass over a peer's line, sizing nothing
const std = @import("std");
pub fn f(r: *std.Io.Reader) !bool {
    const line = try r.takeDelimiterExclusive('\n');
    var key_buf: [256]u8 = undefined;
    _ = std.fmt.bufPrint(&key_buf, "tar.{s}.remote", .{line}) catch return false;
    return std.mem.eql(u8, line, "tgz");
}
