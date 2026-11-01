// review 5: a20/c12_recursion.zig
const std = @import("std");
pub fn spin(io: std.Io, n: u64) void {
    spin(io, n +% 1);
}
