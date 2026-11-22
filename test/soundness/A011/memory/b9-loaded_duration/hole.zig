// A011: std's Duration loaded through a pointer, its raw nanoseconds read: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn f(at: *const std.Io.Duration) i96 {
    const held = at.*;
    return held.nanoseconds;
}
