// A013: std's debug namespace unwrapped from an optional by .?, its assert called: a finding.
const aegis = @import("aegis");
const std = @import("std");
const held: ?type = std.debug;
pub fn f(n: u32) u32 {
    held.?.assert(n > 0);
    return n - 1;
}
