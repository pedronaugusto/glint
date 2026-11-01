// matrix: an inline loop writes an error's name to each of its writers, the peer's among them
const std = @import("std");
pub fn reply(io: std.Io, stream: std.Io.net.Stream, err: anyerror, log: *std.Io.Writer) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    const w = &sw.interface;
    inline for (.{ log, w }) |out| try out.print("{s}\n", .{@errorName(err)});
    try w.flush();
}
