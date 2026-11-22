// A009: a reader made over a file a local holds, outside a declared input seam: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn open(given: std.Io.File, io: std.Io, buffer: []u8) std.Io.File.Reader {
    var file: std.Io.File = undefined;
    file = given;
    return file.reader(io, buffer);
}
