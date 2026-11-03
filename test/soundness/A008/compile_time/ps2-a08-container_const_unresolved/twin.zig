// pre-sweep-2 A008 twin: the same constant over a public key.
const std = @import("std");
const dep = @import("dep.zig");
pub const baked: std.meta.Child(dep.Shown) = .{ .bytes = @splat(7) };
pub fn key() *const @TypeOf(baked) {
    return &baked;
}
