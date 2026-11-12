// A009: the same reader made in the input seam the project declares.
const aegis = @import("aegis");
const std = @import("std");
pub fn open(file: std.Io.File, io: std.Io, buffer: []u8) std.Io.File.Reader {
    return file.reader(io, buffer);
}
