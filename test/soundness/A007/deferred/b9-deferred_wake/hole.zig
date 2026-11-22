// A007: a word woken by hand at the scope's end, through an alias: a finding.
const aegis = @import("aegis");
const std = @import("std");
const Io = std.Io;
pub fn finish(io: Io, word: *u32) void {
    defer Io.futexWake(io, u32, word, 1);
    word.* = 1;
}
