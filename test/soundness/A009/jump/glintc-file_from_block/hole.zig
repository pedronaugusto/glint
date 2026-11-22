// A009: a reader made over a file a labeled block gives, outside a declared input seam: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn open(given: std.Io.File, io: std.Io, buffer: []u8) std.Io.File.Reader {
    const file = blk: {
        break :blk given;
    };
    return file.reader(io, buffer);
}
