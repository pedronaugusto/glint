// A009: the same, in the seam the case declares.
const aegis = @import("aegis");
const std = @import("std");
pub fn f(s: *const std.Io.net.Socket, io: std.Io, buffer: []u8) !std.Io.net.IncomingMessage {
    return s.receive(io, buffer);
}
