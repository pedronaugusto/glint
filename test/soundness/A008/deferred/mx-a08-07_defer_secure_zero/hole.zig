// matrix A008: a hand wipe at the scope's exit.
const std = @import("std");
pub fn use(buffer: []u8) u8 {
    defer std.crypto.secureZero(u8, buffer);
    return buffer[0];
}
