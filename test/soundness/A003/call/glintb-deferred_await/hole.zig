// glint-b: A003 call (a deferred lend): io.concurrent runs peek with the stream later; the caller closes it before awaiting the future: must not be clean
const std = @import("std");
const Io = std.Io;
const net = Io.net;
fn peek(io: Io, stream: *net.Stream) void {
    _ = io;
    _ = stream.socket;
}
pub fn f(io: Io, address: net.IpAddress) !void {
    var stream = try address.connect(io, .{ .mode = .stream });
    var task = try io.concurrent(peek, .{ io, &stream });
    stream.close(io);
    task.await(io);
}
