// A013: std's debug namespace a labeled block's result, its assert called: a finding.
const aegis = @import("aegis");
const std = @import("std");
const ns = blk: {
    break :blk std.debug;
};
pub fn f(n: u32) u32 {
    ns.assert(n > 0);
    return n - 1;
}
