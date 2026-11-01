// matrix: an error's name the fallback of an optional detail by `orelse`, written to the peer
const std = @import("std");
pub fn reply(io: std.Io, stream: std.Io.net.Stream, err: anyerror, detail: ?[]const u8) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    const w = &sw.interface;
    try w.writeAll(detail orelse @errorName(err));
    try w.flush();
}
