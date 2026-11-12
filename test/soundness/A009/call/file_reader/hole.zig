// A009: a reader made over a file outside a declared input seam.
const aegis = @import("aegis");
const std = @import("std");
pub fn open(file: std.Io.File, io: std.Io, buffer: []u8) std.Io.File.Reader {
    return file.reader(io, buffer);
}
