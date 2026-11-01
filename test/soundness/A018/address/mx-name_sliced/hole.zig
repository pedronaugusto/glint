// matrix: an error's name cut to a length, the slice written to the peer
const std = @import("std");
pub fn reply(io: std.Io, stream: std.Io.net.Stream, err: anyerror) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    const w = &sw.interface;
    const name = @errorName(err);
    try w.writeAll(@errorName(err)[0..@min(name.len, 16)]);
    try w.flush();
}
