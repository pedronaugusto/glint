// matrix: an error's name written to the peer byte by byte, each byte a loop's capture
const std = @import("std");
pub fn reply(io: std.Io, stream: std.Io.net.Stream, err: anyerror) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    const w = &sw.interface;
    for (@errorName(err)) |byte| try w.writeByte(byte);
    try w.flush();
}
