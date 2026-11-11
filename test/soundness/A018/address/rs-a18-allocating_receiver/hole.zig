// rule-small: an error's name printed through a member named `writer` of the program's own struct, which points at the peer's stream writer
const std = @import("std");
const Peer = struct { writer: *std.Io.Writer };
pub fn reply(io: std.Io, stream: std.Io.net.Stream, err: anyerror) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    const peer: Peer = .{ .writer = &sw.interface };
    try peer.writer.print("failed: {s}\n", .{@errorName(err)});
    try peer.writer.flush();
}
