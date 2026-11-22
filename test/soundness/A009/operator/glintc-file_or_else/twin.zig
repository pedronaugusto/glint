// A009: a writer made over a file an orelse gives: output, none.
const aegis = @import("aegis");
const std = @import("std");
pub fn open(given: ?std.Io.File, fallback: std.Io.File, io: std.Io, buffer: []u8) std.Io.File.Writer {
    return (given orelse fallback).writer(io, buffer);
}
