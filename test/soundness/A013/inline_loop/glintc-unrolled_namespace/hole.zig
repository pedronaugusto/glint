// A013: std's debug namespace an unrolled loop's capture, its assert called: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn f(n: u32) u32 {
    inline for (.{std.debug}) |ns| ns.assert(n > 0);
    return n - 1;
}
