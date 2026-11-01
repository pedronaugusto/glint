// matrix: an error's name cut to a length, the slice written to the log
const std = @import("std");
pub fn reply(io: std.Io, stream: std.Io.net.Stream, err: anyerror, log: *std.Io.Writer) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    const w = &sw.interface;
    try w.writeAll("internal error\n");
    const name = @errorName(err);
    try log.writeAll(@errorName(err)[0..@min(name.len, 16)]);
    try w.flush();
}
