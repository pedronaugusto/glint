// warp-fast: the input bound is moved by @memcpy into the word the loop
// compares against; the loop has no cancellation point.
const std = @import("std");
pub fn spin(io: std.Io, r: *std.Io.Reader) !u64 {
    _ = io;
    const bytes = try r.takeArray(8);
    var n: u64 = 0;
    @memcpy(std.mem.asBytes(&n), bytes);
    var t: u64 = 0;
    while (t != n) t +%= 1;
    return t;
}
