// A013: std's debug namespace a comptime expression's value, its assert called: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn f(n: u32) u32 {
    const ns = comptime std.debug;
    ns.assert(n > 0);
    return n - 1;
}
