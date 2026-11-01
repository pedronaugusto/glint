// matrix: a known error's name concatenated into a line by `++`, written to the log
const std = @import("std");
pub fn reply(io: std.Io, stream: std.Io.net.Stream, err: anyerror, log: *std.Io.Writer) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    const w = &sw.interface;
    try w.writeAll("internal error\n");
    if (err == error.QuotaExceeded) try log.writeAll("error: " ++ @errorName(error.QuotaExceeded) ++ "\n");
    try w.flush();
}
