// A009: the read a stream runs, made outside a declared input seam.
const aegis = @import("aegis");
const std = @import("std");
pub fn f(io: std.Io, stream: std.Io.net.Stream, data: [][]u8) !std.Io.Operation.Result {
    return io.operate(.{ .net_read = .{ .socket_handle = stream.socket.handle, .data = data } });
}
