// matrix: a log's writer handed to a helper that writes an error's name to it
const std = @import("std");
fn send(out: *std.Io.Writer, e: anyerror) !void {
    try out.print("{s}\n", .{@errorName(e)});
}
pub fn reply(io: std.Io, stream: std.Io.net.Stream, err: anyerror) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    var log_buf: [256]u8 = undefined;
    var log: std.Io.Writer = .fixed(&log_buf);
    try send(&log, err);
    try sw.interface.writeAll("internal error\n");
    try sw.interface.flush();
}
