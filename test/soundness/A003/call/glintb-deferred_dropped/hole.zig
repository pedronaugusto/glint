// glint-b: A003 call (a deferred lend's future): the future is dropped, never awaited, so peek may still hold the stream at its close: must not be clean
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
    _ = try io.concurrent(peek, .{ io, &stream });
}
