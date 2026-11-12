// A008: the same wipe inside the seam the project declares for it is no finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn wipe(key: *[32]u8) void {
    std.crypto.secureZero(u8, key);
}
