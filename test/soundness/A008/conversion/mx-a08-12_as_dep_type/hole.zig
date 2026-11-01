// matrix A008: @as makes a secret key of the type a dependency's function gives, held by value.
const dep = @import("dep.zig");
pub fn seedOf(bytes: [64]u8) [32]u8 {
    const key = @as(dep.Key(), .{ .bytes = bytes });
    return key.seed();
}
