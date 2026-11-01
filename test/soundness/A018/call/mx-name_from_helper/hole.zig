// matrix: an error's name returned by a helper and written to the peer
const std = @import("std");
fn describe(e: anyerror) []const u8 {
    return @errorName(e);
}
pub fn reply(io: std.Io, stream: std.Io.net.Stream, err: anyerror) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    const w = &sw.interface;
    try w.writeAll(describe(err));
    try w.flush();
}
