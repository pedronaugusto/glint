// warp-fast: a local File.Writer handed to one of two writers a comptime flag chooses, whose results
// differ: the call gives a choice of two error unions, an operation on a stream all the
// same, its failure passed on without its err.
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
    return try (if (frame) framed else plain)(&w.interface);
}
