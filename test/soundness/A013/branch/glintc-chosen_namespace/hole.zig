// A013: std's debug namespace chosen by an if, its assert called: a finding.
const aegis = @import("aegis");
const std = @import("std");
const wide = false;
const ns = if (wide) std.debug else std.debug;
pub fn f(n: u32) u32 {
    ns.assert(n > 0);
    return n - 1;
}
