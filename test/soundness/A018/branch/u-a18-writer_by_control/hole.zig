// matrix A018 branch: the writer a branch stores is the peer's: an error's name written through it reaches the peer
const std = @import("std");
pub fn f(io: std.Io, stream: std.Io.net.Stream, err: anyerror) !void {
    var buf: [64]u8 = undefined;
    var sw = stream.writer(io, &buf);
    var other: [64]u8 = undefined;
    var fixed: std.Io.Writer = .fixed(&other);
    var w: *std.Io.Writer = &fixed;
    if (sw.interface.end > 0) w = &sw.interface;
    try w.writeAll(@errorName(err));
}
