// rule-small: parameters declared `fn` and `*const fn` are functions, which hold no state: no Io is given
const std = @import("std");
fn next(n: u64) u64 {
    return n +% 1;
}
pub fn spin(comptime step: fn (u64) u64, other: *const fn (u64) u64) void {
    var n: u64 = 0;
    while (true) n = other(step(n));
}
pub fn start() void {
    spin(next, &next);
}
