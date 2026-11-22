// A009: a writer made over a file a local holds: output, none.
const aegis = @import("aegis");
const std = @import("std");
pub fn open(given: std.Io.File, io: std.Io, buffer: []u8) std.Io.File.Writer {
    var file: std.Io.File = undefined;
    file = given;
    return file.writer(io, buffer);
}
