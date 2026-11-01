// matrix: an error's name written by the writer type's function, the log its first argument
const std = @import("std");
pub fn reply(io: std.Io, stream: std.Io.net.Stream, err: anyerror, log: *std.Io.Writer) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    const w = &sw.interface;
    try w.writeAll("internal error\n");
    try std.Io.Writer.writeAll(log, @errorName(err));
    try w.flush();
}
