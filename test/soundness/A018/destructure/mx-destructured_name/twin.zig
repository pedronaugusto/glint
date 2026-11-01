// matrix: an error's name destructured beside a status code; the code to the peer, the name to the log
const std = @import("std");
pub fn reply(io: std.Io, stream: std.Io.net.Stream, err: anyerror, log: *std.Io.Writer) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    const w = &sw.interface;
    try w.writeAll("internal error\n");
    const name, const code = .{ @errorName(err), @as(u16, 500) };
    try w.print("{d}\n", .{code});
    try log.print("{d} {s}\n", .{ code, name });
    try w.flush();
}
