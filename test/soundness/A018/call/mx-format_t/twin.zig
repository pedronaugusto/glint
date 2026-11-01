// matrix: an error printed to the log by `{t}`; the peer gets public text
const std = @import("std");
pub fn reply(io: std.Io, stream: std.Io.net.Stream, err: anyerror, log: *std.Io.Writer) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    const w = &sw.interface;
    try w.writeAll("internal error\n");
    try log.print("{t}\n", .{err});
    try w.flush();
}
