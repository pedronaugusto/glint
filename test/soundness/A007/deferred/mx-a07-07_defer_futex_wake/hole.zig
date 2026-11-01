// matrix A007: a futex wake at the scope's exit, on a word the program writes as it likes.
const std = @import("std");
pub fn release(io: std.Io, word: *u32) void {
    defer io.futexWake(u32, word, 1);
    word.* = 0;
}
