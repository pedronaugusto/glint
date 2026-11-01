// warp-fast: a labeled block's break gives a pointer to a lock: a borrow.
const std = @import("std");
const Lock = blk: {
    break :blk *std.Io.Mutex;
};
pub const Shared = struct { lock: Lock };
