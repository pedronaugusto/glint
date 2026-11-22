// A008: aegis's secret unwrapped from an optional by .?, its wipe called: none.
const aegis = @import("aegis");
const std = @import("std");
const held: ?type = aegis.secret;
pub fn wipe(key: *[32]u8) void {
    held.?.wipe(key);
}
