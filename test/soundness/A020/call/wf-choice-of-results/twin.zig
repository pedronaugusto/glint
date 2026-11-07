// warp-fast: the same choice of writers, its WriteFailed returning w.err, error.Canceled among it.
const std = @import("std");
fn plain(w: *std.Io.Writer) std.Io.Writer.Error!u8 {
    try w.writeAll("plain");
    return 5;
}
fn framed(w: *std.Io.Writer) std.Io.Writer.Error!u16 {
    try w.writeAll("[framed]");
    return 8;
}
pub fn put(f: std.Io.File, io: std.Io, comptime frame: bool) !usize {
    var buf: [64]u8 = undefined;
    var w = f.writer(io, &buf);
    return (if (frame) framed else plain)(&w.interface) catch return w.err.?;
}

/// A binding: the ruling's remedy for a public generic nothing else binds.
pub fn both(f: std.Io.File, io: std.Io) !usize {
    return try put(f, io, false) + try put(f, io, true);
}
