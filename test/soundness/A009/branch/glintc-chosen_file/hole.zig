// A009: a reader made over a file an if chooses, outside a declared input seam: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn open(first: bool, a: std.Io.File, b: std.Io.File, io: std.Io, buffer: []u8) std.Io.File.Reader {
    const file = if (first) a else b;
    return file.reader(io, buffer);
}
