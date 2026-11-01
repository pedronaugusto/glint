// matrix: an error printed to the peer by `{t}`, which formats its name
const std = @import("std");
pub fn reply(io: std.Io, stream: std.Io.net.Stream, err: anyerror) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    const w = &sw.interface;
    try w.print("{t}\n", .{err});
    try w.flush();
}
