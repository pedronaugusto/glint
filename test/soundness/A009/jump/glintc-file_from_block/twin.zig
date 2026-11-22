// A009: a writer made over a file a labeled block gives: output, none.
const aegis = @import("aegis");
const std = @import("std");
pub fn open(given: std.Io.File, io: std.Io, buffer: []u8) std.Io.File.Writer {
    const file = blk: {
        break :blk given;
    };
    return file.writer(io, buffer);
}
