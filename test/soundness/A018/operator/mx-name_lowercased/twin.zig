// matrix: an error's name lowercased byte by byte with a bit operator, written to the log
const std = @import("std");
pub fn reply(io: std.Io, stream: std.Io.net.Stream, err: anyerror, log: *std.Io.Writer) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    const w = &sw.interface;
    try w.writeAll("internal error\n");
    for (@errorName(err)) |byte| try log.writeByte(byte | 0x20);
    try w.flush();
}
