// glint-b: A003 call (lent by its kind): callees that only read the stream's members or discard
// it, called directly or through @call's tuple, hand it back held: must stay clean
const std = @import("std");
const Io = std.Io;
const net = Io.net;
fn peek(io: Io, stream: *net.Stream) void {
    _ = io;
    _ = stream.socket;
}
fn ignore(io: Io, stream: *net.Stream) void {
    _ = io;
    _ = stream;
}
pub fn f(io: Io, address: net.IpAddress) !void {
    var stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    @call(.auto, peek, .{ io, &stream });
    ignore(io, &stream);
}
