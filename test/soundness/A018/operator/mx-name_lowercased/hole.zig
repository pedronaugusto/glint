// matrix: an error's name lowercased byte by byte with a bit operator, written to the peer
const std = @import("std");
pub fn reply(io: std.Io, stream: std.Io.net.Stream, err: anyerror) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    const w = &sw.interface;
    for (@errorName(err)) |byte| try w.writeByte(byte | 0x20);
    try w.flush();
}
