// matrix: the peer's stream captured out of an optional, its writer given public text
const std = @import("std");
pub fn reply(io: std.Io, peer: ?std.Io.net.Stream, err: anyerror, log: *std.Io.Writer) !void {
    var buf: [256]u8 = undefined;
    try log.print("{s}\n", .{@errorName(err)});
    if (peer) |stream| {
        var sw = stream.writer(io, &buf);
        try sw.interface.print("{s}\n", .{"internal error"});
        try sw.interface.flush();
    }
}
