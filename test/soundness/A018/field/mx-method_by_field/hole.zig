// matrix: the write named by `@field` of the writer type, given an error's name
const std = @import("std");
pub fn reply(io: std.Io, stream: std.Io.net.Stream, err: anyerror) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    const w = &sw.interface;
    const method = "writeAll";
    try @field(std.Io.Writer, method)(w, @errorName(err));
    try w.flush();
}
