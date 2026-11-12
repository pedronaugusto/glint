// A008: std's hand wipe outside a seam: SecretBytes is the answer.
const aegis = @import("aegis");
const std = @import("std");
pub fn wipe(key: *[32]u8) void {
    std.crypto.secureZero(u8, key);
}
