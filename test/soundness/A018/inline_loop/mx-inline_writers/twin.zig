// matrix: an inline loop writes an error's name to each of its writers, all of them logs
const std = @import("std");
pub fn reply(io: std.Io, stream: std.Io.net.Stream, err: anyerror, log: *std.Io.Writer, trace: *std.Io.Writer) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    const w = &sw.interface;
    try w.writeAll("internal error\n");
    inline for (.{ log, trace }) |out| try out.print("{s}\n", .{@errorName(err)});
    try w.flush();
}
