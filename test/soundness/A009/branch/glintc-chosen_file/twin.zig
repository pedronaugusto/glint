// A009: a writer made over a file an if chooses: output, none.
const aegis = @import("aegis");
const std = @import("std");
pub fn open(first: bool, a: std.Io.File, b: std.Io.File, io: std.Io, buffer: []u8) std.Io.File.Writer {
    const file = if (first) a else b;
    return file.writer(io, buffer);
}
