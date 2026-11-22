// A013: std's debug namespace a container's member, its assert called: a finding.
const aegis = @import("aegis");
const std = @import("std");
const Kit = struct {
    const ns = std.debug;
};
pub fn f(n: u32) u32 {
    Kit.ns.assert(n > 0);
    return n - 1;
}
