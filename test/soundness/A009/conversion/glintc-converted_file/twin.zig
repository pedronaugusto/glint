// A009: a writer made over a file @as converts: output, none.
const aegis = @import("aegis");
const std = @import("std");
pub fn open(given: std.Io.File, io: std.Io, buffer: []u8) std.Io.File.Writer {
    return @as(std.Io.File, given).writer(io, buffer);
}
