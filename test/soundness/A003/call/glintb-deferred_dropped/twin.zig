// glint-b: A003 call (a deferred lend's future): the future is cancelled before the stream's deferred close: must stay clean
const std = @import("std");
const Io = std.Io;
const net = Io.net;
fn peek(io: Io, stream: *net.Stream) void {
    _ = io;
    _ = stream.socket;
}
pub fn f(io: Io, address: net.IpAddress) !void {
    var stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var task = try io.concurrent(peek, .{ io, &stream });
    task.cancel(io);
}
