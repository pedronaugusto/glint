// A007: std's Io captured from an optional, its reader-writer lock reached through it: a finding.
const aegis = @import("aegis");
const std = @import("std");
const held: ?type = std.Io;
pub fn make() void {
    if (held) |io| {
        var lock: io.RwLock = .init;
        _ = &lock;
    }
}
