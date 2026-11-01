// matrix: an error's name one part of an array of parts written to the peer at once
const std = @import("std");
pub fn reply(io: std.Io, stream: std.Io.net.Stream, err: anyerror) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    const w = &sw.interface;
    var parts = [_][]const u8{ "error: ", @errorName(err), "\n" };
    try w.writeVecAll(&parts);
    try w.flush();
}
