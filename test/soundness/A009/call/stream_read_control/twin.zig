// A009: the same, in the seam the case declares.
const aegis = @import("aegis");
const std = @import("std");
pub fn f(s: *const std.Io.net.Stream, io: std.Io, data: [][]u8, control: []u8) !std.Io.net.Stream.ReadResult {
    return s.readWithControl(io, data, control);
}
