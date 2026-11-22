// A007: a word woken by hand, std's futex called as a method of the Io value: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn wake(io: std.Io, word: *u32) void {
    io.futexWake(u32, word, 1);
}
