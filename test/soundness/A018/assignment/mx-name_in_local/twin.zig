// matrix: an error's name held in a local, then written to the log; the peer gets public text
const std = @import("std");
pub fn reply(io: std.Io, stream: std.Io.net.Stream, err: anyerror, log: *std.Io.Writer) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    const w = &sw.interface;
    try w.writeAll("internal error\n");
    const name = @errorName(err);
    try log.writeAll(name);
    try w.flush();
}
