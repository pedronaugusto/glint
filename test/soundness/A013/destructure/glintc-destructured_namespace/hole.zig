// A013: std's debug namespace named by a destructure, its assert called: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn f(n: u32) u32 {
    const ns, _ = .{ std.debug, @as(u8, 0) };
    ns.assert(n > 0);
    return n - 1;
}
