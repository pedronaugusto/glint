// rule-small: a parameter declared `anytype` may be given an Io; a `fn` parameter beside it changes nothing
const std = @import("std");
fn next(n: u64) u64 {
    return n +% 1;
}
pub fn spin(io: anytype, comptime step: fn (u64) u64) void {
    _ = io;
    var n: u64 = 0;
    while (true) n = step(n);
}
pub fn start(io: std.Io) void {
    spin(io, next);
}
