// A013: std's debug namespace held by a const, its assert called: a finding.
const aegis = @import("aegis");
const std = @import("std");
const ns = std.debug;
pub fn f(n: u32) u32 {
    ns.assert(n > 0);
    return n - 1;
}
