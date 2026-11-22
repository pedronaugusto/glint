// A009: a writer made over a file a destructure names: output, none.
const aegis = @import("aegis");
const std = @import("std");
pub fn open(given: std.Io.File, io: std.Io, buffer: []u8) std.Io.File.Writer {
    const file, _ = .{ given, @as(u8, 0) };
    return file.writer(io, buffer);
}
