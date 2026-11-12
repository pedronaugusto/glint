// A009: a socket read directly, with its control data outside a declared input seam (review 8, M4).
const aegis = @import("aegis");
const std = @import("std");
pub fn f(s: *const std.Io.net.Stream, io: std.Io, data: [][]u8, control: []u8) !std.Io.net.Stream.ReadResult {
    return s.readWithControl(io, data, control);
}
