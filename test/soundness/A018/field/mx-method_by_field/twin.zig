// matrix: the write named by `@field` of the writer type, given an error's name for the log
const std = @import("std");
pub fn reply(io: std.Io, stream: std.Io.net.Stream, err: anyerror, log: *std.Io.Writer) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    const w = &sw.interface;
    try w.writeAll("internal error\n");
    const method = "writeAll";
    try @field(std.Io.Writer, method)(log, @errorName(err));
    try w.flush();
}
