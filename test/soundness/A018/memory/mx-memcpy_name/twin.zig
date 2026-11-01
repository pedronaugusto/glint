// matrix: an error's name copied into a line by `@memcpy`, the line written to the log
const std = @import("std");
pub fn reply(io: std.Io, stream: std.Io.net.Stream, err: anyerror, log: *std.Io.Writer) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    const w = &sw.interface;
    try w.writeAll("internal error\n");
    var line: [64]u8 = undefined;
    const name = @errorName(err);
    const n = @min(name.len, line.len);
    @memcpy(line[0..n], name[0..n]);
    try log.writeAll(line[0..n]);
    try w.flush();
}
