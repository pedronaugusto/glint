// A008: aegis's secret captured from an optional, its wipe called through the capture: none.
const aegis = @import("aegis");
const std = @import("std");
const held: ?type = aegis.secret;
pub fn wipe(key: *[32]u8) void {
    if (held) |secret| secret.wipe(key);
}
