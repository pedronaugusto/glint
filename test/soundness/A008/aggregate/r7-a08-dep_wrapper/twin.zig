// review 7 A008: the same record with the key sealed in aegis's Secret.
const std = @import("std");
const dep = @import("dep.zig");
pub fn label(io: std.Io) u8 {
    var w = dep.openSealed(io);
    defer w.key.deinit();
    return w.label;
}
