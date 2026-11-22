// A009: a writer made over a file reached through a pointer: output, none.
const aegis = @import("aegis");
const std = @import("std");
pub fn open(file: *const std.Io.File, io: std.Io, buffer: []u8) std.Io.File.Writer {
    return file.writer(io, buffer);
}
