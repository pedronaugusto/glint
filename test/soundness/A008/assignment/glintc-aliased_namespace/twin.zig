// A008: aegis's secret held by a const, its wipe called through it: none.
const aegis = @import("aegis");
const std = @import("std");
const secret = aegis.secret;
pub fn wipe(key: *[32]u8) void {
    secret.wipe(key);
}
