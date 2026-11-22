// A008: aegis's secret reached through a pointer to it, its wipe called: none.
const aegis = @import("aegis");
const std = @import("std");
const secret = &aegis.secret;
pub fn wipe(key: *[32]u8) void {
    secret.*.wipe(key);
}
