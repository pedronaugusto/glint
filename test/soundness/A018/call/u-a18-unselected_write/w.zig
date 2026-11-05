// An import of the case's, not selected: it writes what it is given to a peer.
const std = @import("std");
pub fn send(io: std.Io, stream: std.Io.net.Stream, text: []const u8) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    try sw.interface.writeAll(text);
    try sw.interface.flush();
}
