// A009: a writer made over a file loaded from a slice in memory: output, none.
const aegis = @import("aegis");
const std = @import("std");
pub fn open(files: []const std.Io.File, io: std.Io, buffer: []u8) std.Io.File.Writer {
    return files[0].writer(io, buffer);
}
