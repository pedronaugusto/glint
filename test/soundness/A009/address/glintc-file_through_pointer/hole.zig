// A009: a reader made over a file reached through a pointer, outside a declared input seam: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn open(file: *const std.Io.File, io: std.Io, buffer: []u8) std.Io.File.Reader {
    return file.reader(io, buffer);
}
