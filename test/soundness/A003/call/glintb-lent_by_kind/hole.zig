// glint-b: A003 call (lent by its kind): a callee closes the stream it is lent, and the caller's
// defer closes it again; a std handle's release is its close, not a guard's deinit: must not be clean
const std = @import("std");
const Io = std.Io;
const net = Io.net;
fn shut(io: Io, stream: *net.Stream) void {
    stream.close(io);
}
pub fn f(io: Io, address: net.IpAddress) !void {
    var stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    shut(io, &stream);
}
