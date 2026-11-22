// A013: std's debug namespace an element of a tuple, its assert called: a finding.
const aegis = @import("aegis");
const std = @import("std");
const kinds = .{std.debug};
pub fn f(n: u32) u32 {
    kinds[0].assert(n > 0);
    return n - 1;
}
