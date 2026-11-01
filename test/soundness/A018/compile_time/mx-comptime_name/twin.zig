// matrix: a known error's name, made at compile time, written to the log
const std = @import("std");
pub fn reply(io: std.Io, stream: std.Io.net.Stream, err: anyerror, log: *std.Io.Writer) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    const w = &sw.interface;
    try w.writeAll("internal error\n");
    if (err == error.QuotaExceeded) try log.writeAll(comptime @errorName(error.QuotaExceeded));
    try w.flush();
}
