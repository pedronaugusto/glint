// A013: std's debug namespace an element of tuples joined by ++, its assert called: a finding.
const aegis = @import("aegis");
const std = @import("std");
const both = .{std.mem} ++ .{std.debug};
pub fn f(n: u32) u32 {
    both[1].assert(n > 0);
    return n - 1;
}
