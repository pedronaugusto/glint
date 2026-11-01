// c1: the same error name written to the peer after before.zig: what the run kept while
// before.zig's budget ran out is no answer here, so it is flagged or left undecided, never clean
const std = @import("std");
fn send2(out: *std.Io.Writer, e: anyerror) !void {
    try out.print("{s}\n", .{@errorName(e)});
}
pub fn answer(io: std.Io, stream: std.Io.net.Stream, err: anyerror) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    try send2(&sw.interface, err);
    try sw.interface.flush();
}
