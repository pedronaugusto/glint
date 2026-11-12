// A009: a datagram received outside a declared input seam (review 8, M4).
const aegis = @import("aegis");
const std = @import("std");
pub fn f(s: *const std.Io.net.Socket, io: std.Io, buffer: []u8) !std.Io.net.IncomingMessage {
    return s.receive(io, buffer);
}
