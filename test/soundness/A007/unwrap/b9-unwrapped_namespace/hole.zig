// A007: std's Io unwrapped from an optional by .?, its lock reached through it: a finding.
const aegis = @import("aegis");
const std = @import("std");
const held: ?type = std.Io;
pub fn make() held.?.Mutex {
    return .init;
}
