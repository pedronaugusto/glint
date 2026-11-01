// matrix A008: the same key sealed in aegis's Secret.
const aegis = @import("aegis");
const dep = @import("dep.zig");
pub fn seedOf(bytes: [64]u8) [32]u8 {
    var key = aegis.Secret(dep.Key()).init(@as(dep.Key(), .{ .bytes = bytes }));
    defer key.deinit();
    return key.expose().seed();
}
