// P014: standard output returned by a function of the program, written through a streaming
// writer.
const std = @import("std");
fn out() std.Io.File {
    return .stdout();
}
pub fn say(io: std.Io) !void {
    var buf: [64]u8 = undefined;
    var w = out().writerStreaming(io, &buf);
    try w.interface.writeAll("hi\n");
}
