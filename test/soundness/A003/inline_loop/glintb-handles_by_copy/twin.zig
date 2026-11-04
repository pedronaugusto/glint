// glint-b: A003 inline_loop (std handles closed by copy): a std handle is a value, so closing each
// copy the loop takes closes the pair's handles: must stay clean
const std = @import("std");
const Io = std.Io;
const net = Io.net;
fn pairOf(io: Io, address: net.IpAddress) ![2]net.Stream {
    const one = try address.connect(io, .{ .mode = .stream });
    errdefer one.close(io);
    const two = try address.connect(io, .{ .mode = .stream });
    return .{ one, two };
}
pub fn f(io: Io, address: net.IpAddress) !void {
    const pair = try pairOf(io, address);
    defer for (pair) |s| s.close(io);
}
