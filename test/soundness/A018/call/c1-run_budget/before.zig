// c1: a program's other file, read first: it spends this file's fact budget inside the answers
// the run keeps for every file (std's Writer.print, the stream's writer)
const std = @import("std");
fn send(out: *std.Io.Writer, e: anyerror) !void {
    try out.print("{s}\n", .{@errorName(e)});
}
pub fn reply(io: std.Io, stream: std.Io.net.Stream, err: anyerror) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    try send(&sw.interface, err);
    try sw.interface.flush();
}
