// A007: std's Io held by a const, its lock reached through it: a finding.
const aegis = @import("aegis");
const std = @import("std");
const io = std.Io;
pub fn make() io.Mutex {
    return .init;
}
