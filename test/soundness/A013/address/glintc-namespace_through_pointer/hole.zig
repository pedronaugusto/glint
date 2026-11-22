// A013: std's debug namespace reached through a pointer to it, its assert called: a finding.
const aegis = @import("aegis");
const std = @import("std");
const ns = &std.debug;
pub fn f(n: u32) u32 {
    ns.*.assert(n > 0);
    return n - 1;
}
