// A008: aegis's secret an unrolled loop's capture, its wipe called through it: none.
const aegis = @import("aegis");
const std = @import("std");
pub fn wipe(key: *[32]u8) void {
    inline for (.{aegis.secret}) |secret| secret.wipe(key);
}
