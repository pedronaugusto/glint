// matrix: the text a labeled block breaks with, an error's name when verbose, written to the log
const std = @import("std");
pub fn reply(io: std.Io, stream: std.Io.net.Stream, err: anyerror, log: *std.Io.Writer, verbose: bool) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    const w = &sw.interface;
    try w.writeAll("internal error\n");
    try log.writeAll(text: {
        if (verbose) break :text @errorName(err);
        break :text "internal error";
    });
    try w.flush();
}
