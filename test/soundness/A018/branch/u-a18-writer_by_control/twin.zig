// matrix A018 branch: the writer a branch stores under a condition that reads the peer's writer is another in-memory one: a branch transfers no writer
const std = @import("std");
pub fn f(io: std.Io, stream: std.Io.net.Stream, err: anyerror) !void {
    var buf: [64]u8 = undefined;
    var sw = stream.writer(io, &buf);
    var one: [64]u8 = undefined;
    var two: [64]u8 = undefined;
    var first: std.Io.Writer = .fixed(&one);
    var second: std.Io.Writer = .fixed(&two);
    var w: *std.Io.Writer = &first;
    if (sw.interface.end > 0) w = &second;
    try w.writeAll(@errorName(err));
    try sw.interface.flush();
}
