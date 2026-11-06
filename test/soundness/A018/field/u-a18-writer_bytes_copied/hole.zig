// A writer reaching a peer, copied as a whole into a local: the copy is that writer, and an error's name
// written through it crosses to the peer.
const std = @import("std");
pub fn reply(io: std.Io, stream: std.Io.net.Stream, err: anyerror) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    const w: *std.Io.Writer = &sw.interface;
    try w.print("{s}\n", .{@errorName(err)});
    try w.flush();
}
