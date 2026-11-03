// pre-sweep-2 A008: a container-level constant whose type does not resolve (`std.meta.Child` of a
// dependency's array: an Ed25519.SecretKey) is cleared as "settled as the program compiles"; the
// key is held by value, as the same constant typed `Ed25519.SecretKey` or a dependency's alias
// of it is reported.
const std = @import("std");
const dep = @import("dep.zig");
pub const baked: std.meta.Child(dep.Keys) = .{ .bytes = @splat(7) };
pub fn key() *const @TypeOf(baked) {
    return &baked;
}
