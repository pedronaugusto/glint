// matrix: an error's name one part of an array of parts written to the log at once
const std = @import("std");
pub fn reply(io: std.Io, stream: std.Io.net.Stream, err: anyerror, log: *std.Io.Writer) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    const w = &sw.interface;
    try w.writeAll("internal error\n");
    var parts = [_][]const u8{ "error: ", @errorName(err), "\n" };
    try log.writeVecAll(&parts);
    try w.flush();
}
