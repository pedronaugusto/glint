// matrix: the peer's writer handed to a helper that writes an error's name to it
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
