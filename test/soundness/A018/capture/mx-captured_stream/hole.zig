// matrix: the peer's stream captured out of an optional, its writer given an error's name
const std = @import("std");
pub fn reply(io: std.Io, peer: ?std.Io.net.Stream, err: anyerror) !void {
    var buf: [256]u8 = undefined;
    if (peer) |stream| {
        var sw = stream.writer(io, &buf);
        try sw.interface.print("{s}\n", .{@errorName(err)});
        try sw.interface.flush();
    }
}
