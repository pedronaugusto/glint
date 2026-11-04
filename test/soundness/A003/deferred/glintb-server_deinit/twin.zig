// glint-b: A003 deferred (a server's deinit): std's Server is released by `deinit`, which
// closes its socket, deferred or called before the block's end: must stay clean
const std = @import("std");
const net = std.Io.net;
pub fn f(io: std.Io) !void {
    const address: net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var again = try address.listen(io, .{ .reuse_address = true });
    again.deinit(io);
}
