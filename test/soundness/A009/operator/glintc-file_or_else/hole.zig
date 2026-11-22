// A009: a reader made over a file an orelse gives, outside a declared input seam: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn open(given: ?std.Io.File, fallback: std.Io.File, io: std.Io, buffer: []u8) std.Io.File.Reader {
    return (given orelse fallback).reader(io, buffer);
}
