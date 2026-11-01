// matrix: the peer's writer reached through a pointer held in a struct, given an error's name
const std = @import("std");
const Reply = struct { out: *std.Io.Writer };
pub fn reply(io: std.Io, stream: std.Io.net.Stream, err: anyerror) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    const r: Reply = .{ .out = &sw.interface };
    try r.out.print("{s}\n", .{@errorName(err)});
    try r.out.flush();
}
