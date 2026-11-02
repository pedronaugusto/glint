// review 7 A007: the same record with its count under aegis's Guarded.
const std = @import("std");
const dep = @import("dep.zig");
pub const Server = struct {
    state: dep.Safe = .{},
};
