// A writer's address kept as an integer and made a pointer again is that writer: the integer's type holds no
// writer, but the pointer made from it may be one, and an error's name written through it crosses to the peer.
const std = @import("std");
pub fn reply(io: std.Io, stream: std.Io.net.Stream, err: anyerror) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    const at: usize = @intFromPtr(&sw.interface);
    const w: *std.Io.Writer = @ptrFromInt(at);
    try w.print("{s}\n", .{@errorName(err)});
    try w.flush();
}
