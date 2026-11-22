// A009: a reader made over a file in a deferred block, outside a declared input seam: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn open(file: std.Io.File, io: std.Io, buffer: []u8, out: *std.Io.File.Reader) void {
    defer out.* = file.reader(io, buffer);
}
