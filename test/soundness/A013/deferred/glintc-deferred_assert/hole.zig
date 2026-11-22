// A013: std's assert deferred to the scope's end: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn f(n: u32) u32 {
    defer std.debug.assert(n > 0);
    return n - 1;
}
