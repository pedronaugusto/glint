// matrix: an error's name through `@as`, written to the peer
const std = @import("std");
pub fn reply(io: std.Io, stream: std.Io.net.Stream, err: anyerror) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    const w = &sw.interface;
    try w.writeAll(@as([]const u8, @errorName(err)));
    try w.flush();
}
