// warp-fast: an array field holds locks by value.
const std = @import("std");
pub const Shards = struct { locks: [4]std.Io.Mutex };
