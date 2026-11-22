// A013: std's debug namespace converted to a type by @as, its assert called: a finding.
const aegis = @import("aegis");
const std = @import("std");
const ns = @as(type, std.debug);
pub fn f(n: u32) u32 {
    ns.assert(n > 0);
    return n - 1;
}
