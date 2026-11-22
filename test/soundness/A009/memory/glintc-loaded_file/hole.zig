// A009: a reader made over a file loaded from a slice in memory, outside a declared input seam: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn open(files: []const std.Io.File, io: std.Io, buffer: []u8) std.Io.File.Reader {
    return files[0].reader(io, buffer);
}
