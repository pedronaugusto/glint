// A013: std's debug namespace captured from an optional, its assert called: a finding.
const aegis = @import("aegis");
const std = @import("std");
const held: ?type = std.debug;
pub fn f(n: u32) u32 {
    if (held) |ns| ns.assert(n > 0);
    return n - 1;
}
