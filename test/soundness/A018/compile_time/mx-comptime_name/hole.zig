// matrix: a known error's name, made at compile time, written to the peer
const std = @import("std");
pub fn reply(io: std.Io, stream: std.Io.net.Stream, err: anyerror) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    const w = &sw.interface;
    if (err == error.QuotaExceeded) try w.writeAll(comptime @errorName(error.QuotaExceeded));
    try w.flush();
}
