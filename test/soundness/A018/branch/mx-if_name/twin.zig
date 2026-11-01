// matrix: an `if` chooses an error's name for the log when verbose
const std = @import("std");
pub fn reply(io: std.Io, stream: std.Io.net.Stream, err: anyerror, log: *std.Io.Writer, verbose: bool) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    const w = &sw.interface;
    try w.writeAll("internal error\n");
    try log.writeAll(if (verbose) @errorName(err) else "internal error");
    try w.flush();
}
