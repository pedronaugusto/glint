// review 7 A008: a constant given a dependency's record that holds std's secret key by value as a field: the program copies the key, and nothing in this file names a secret type.
const std = @import("std");
const dep = @import("dep.zig");
pub fn label(io: std.Io) u8 {
    const w = dep.open(io);
    return w.label;
}
