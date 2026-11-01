// warp-fast: a labeled block's break gives a lock type; a field holds it by value.
const std = @import("std");
const Lock = blk: {
    break :blk std.Io.Mutex;
};
pub const Shared = struct { lock: Lock = .init };
