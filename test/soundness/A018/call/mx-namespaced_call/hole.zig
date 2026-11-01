// matrix: an error's name written by the writer type's function, the peer's writer its first argument
const std = @import("std");
pub fn reply(io: std.Io, stream: std.Io.net.Stream, err: anyerror) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    const w = &sw.interface;
    try std.Io.Writer.writeAll(w, @errorName(err));
    try w.flush();
}
