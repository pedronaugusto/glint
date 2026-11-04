// glint-b: A003 deferred (a server's deinit): a listening server never released: must flag
const std = @import("std");
const net = std.Io.net;
pub fn f(io: std.Io) !void {
    const address: net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{ .reuse_address = true });
    _ = &server;
}
