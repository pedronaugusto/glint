// pre-sweep-2 A008 twin: the same local over the public key.
const std = @import("std");
const dep = @import("dep.zig");
pub fn first(comptime n: usize, bytes: [32]u8) !u8 {
    const key: std.meta.Child(dep.Shown) = try .fromBytes(bytes);
    return key.bytes[n];
}
pub fn run(bytes: [32]u8) !u8 {
    return first(3, bytes);
}
