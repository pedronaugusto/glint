// A009: a writer made over a file in a deferred block: output, none.
const aegis = @import("aegis");
const std = @import("std");
pub fn open(file: std.Io.File, io: std.Io, buffer: []u8, out: *std.Io.File.Writer) void {
    defer out.* = file.writer(io, buffer);
}
