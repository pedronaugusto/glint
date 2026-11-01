// warp-fast: File.Reader.seekBy, a method of the reader's own type whose error set holds ReadFailed, passed on
const std = @import("std");
pub fn skip(f: std.Io.File, io: std.Io) !void {
    var buf: [64]u8 = undefined;
    var r = f.readerStreaming(io, &buf);
    try r.seekBy(100);
}
