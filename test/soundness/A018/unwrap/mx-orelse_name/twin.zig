// matrix: an error's name the fallback of an optional detail by `orelse`, written to the log
const std = @import("std");
pub fn reply(io: std.Io, stream: std.Io.net.Stream, err: anyerror, log: *std.Io.Writer, detail: ?[]const u8) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    const w = &sw.interface;
    try w.writeAll("internal error\n");
    try log.writeAll(detail orelse @errorName(err));
    try w.flush();
}
