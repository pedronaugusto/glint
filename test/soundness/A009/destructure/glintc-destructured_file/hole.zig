// A009: a reader made over a file a destructure names, outside a declared input seam: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn open(given: std.Io.File, io: std.Io, buffer: []u8) std.Io.File.Reader {
    const file, _ = .{ given, @as(u8, 0) };
    return file.reader(io, buffer);
}
