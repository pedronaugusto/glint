// A009: a reader made over a file @as converts, outside a declared input seam: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn open(given: std.Io.File, io: std.Io, buffer: []u8) std.Io.File.Reader {
    return @as(std.Io.File, given).reader(io, buffer);
}
