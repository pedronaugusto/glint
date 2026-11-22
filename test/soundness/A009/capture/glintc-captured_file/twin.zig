// A009: a writer made over a file captured from an optional: output, none.
const aegis = @import("aegis");
const std = @import("std");
pub fn open(given: ?std.Io.File, io: std.Io, buffer: []u8) ?std.Io.File.Writer {
    if (given) |file| return file.writer(io, buffer);
    return null;
}
