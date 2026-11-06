// A writer's address as an integer is a number, no writer: written to a writer over the program's memory with
// an error's name, nothing crosses to the peer.
const std = @import("std");
pub fn reply(io: std.Io, stream: std.Io.net.Stream, err: anyerror) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    const at: usize = @intFromPtr(&sw.interface);
    var log_buf: [256]u8 = undefined;
    var fw: std.Io.Writer = .fixed(&log_buf);
    try fw.print("{x} {s}\n", .{ at, @errorName(err) });
    try sw.interface.writeAll("internal error\n");
    try sw.interface.flush();
}
