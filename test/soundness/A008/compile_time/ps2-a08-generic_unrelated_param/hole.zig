// pre-sweep-2 A008: a local typed `std.meta.Child(dep.Keys)` (an Ed25519.SecretKey held by value) is
// undecided in a plain function, but cleared in one with any comptime parameter, which binds nothing
// the type depends on.
const std = @import("std");
const dep = @import("dep.zig");
pub fn first(comptime n: usize, bytes: [64]u8) !u8 {
    const key: std.meta.Child(dep.Keys) = try .fromBytes(bytes);
    return key.bytes[n];
}
pub fn run(bytes: [64]u8) !u8 {
    return first(3, bytes);
}
