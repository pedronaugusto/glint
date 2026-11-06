// Bytes copied out of a peer writer's buffer hold no writer: their type holds none. A writer over them
// (`Writer.fixed`) writes to memory, not to the peer, so an error's name written there stays in the program.
const std = @import("std");
pub fn reply(io: std.Io, stream: std.Io.net.Stream, err: anyerror) !void {
    var buf: [256]u8 = undefined;
    var sw = stream.writer(io, &buf);
    var copy: [256]u8 = undefined;
    @memcpy(copy[0..4], sw.interface.buffer[0..4]);
    var fw: std.Io.Writer = .fixed(&copy);
    try fw.print("{s}\n", .{@errorName(err)});
    try sw.interface.writeAll("internal error\n");
    try sw.interface.flush();
}
