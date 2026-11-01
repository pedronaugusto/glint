// matrix: an error's name destructured beside a status code, both written to the peer
const std = @import("std");
pub fn reply(io: std.Io, stream: std.Io.net.Stream, err: anyerror) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    const w = &sw.interface;
    const name, const code = .{ @errorName(err), @as(u16, 500) };
    try w.print("{d} {s}\n", .{ code, name });
    try w.flush();
}
