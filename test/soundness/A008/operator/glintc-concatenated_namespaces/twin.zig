// A008: aegis's secret an element of tuples joined by ++, its wipe called: none.
const aegis = @import("aegis");
const std = @import("std");
const both = .{std.mem} ++ .{aegis.secret};
pub fn wipe(key: *[32]u8) void {
    both[1].wipe(key);
}
