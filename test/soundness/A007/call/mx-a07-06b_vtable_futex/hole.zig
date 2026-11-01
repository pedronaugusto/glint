// matrix A007: a futex wake called through Io's vtable, past Io.futexWake: a word synchronized by hand.
const std = @import("std");
pub fn release(io: std.Io, word: *u32) void {
    word.* = 0;
    io.vtable.futexWake(io.userdata, word, 1);
}
